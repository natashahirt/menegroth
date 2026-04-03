using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Eto.Drawing;
using Eto.Forms;
using Menegroth.GH.Config;
using Menegroth.GH.Helpers;
using Menegroth.GH.Types;
using Newtonsoft.Json.Linq;

namespace Menegroth.GH.UI
{
    /// <summary>
    /// Chat dialog for interacting with the LLM assistant.
    ///
    /// Supports two modes:
    /// - "design": recommends parameter changes based on geometry and engineering guidance.
    /// - "results": explains check failures, demand/capacity ratios, and suggests iterations.
    ///
    /// Features:
    /// - Proactive opening analysis fired automatically on first open.
    /// - Applicability banner summarizing method eligibility (design mode).
    /// - Param diff panel with Apply/Reject when the agent proposes changes.
    /// - Reflection prompts from each agent turn: pick a card, then answer in the box (prompt shown above input).
    /// - Persistent conversation history keyed by geometry session ID.
    /// </summary>
    public class ChatDialog : Form
    {
        // ─── Core state ──────────────────────────────────────────────────────
        private readonly string _mode;
        private readonly string _baseUrl;
        private readonly string _geometrySummary;
        /// <summary>Short structured summary for results mode (shown in chat and merged into API context).</summary>
        private readonly string _resultsSummary;
        /// <summary>geometry_summary + results_summary for POST /chat (single field on the server).</summary>
        private readonly string _contextForApi;
        private readonly JObject? _paramsJson;
        private readonly JObject? _applicabilitySchema;
        private readonly string _sessionId;
        private readonly bool _autoAnalyze;

        private readonly List<ChatMessage> _messages = new List<ChatMessage>();
        private CancellationTokenSource? _cts;
        private bool _isStreaming;

        // ─── UI controls ─────────────────────────────────────────────────────
        private readonly TextArea _chatArea;
        private readonly TextBox _inputBox;
        private readonly Button _sendButton;

        // Param diff panel — shown when the agent proposes parameter changes.
        private readonly Panel _paramDiffPanel;
        private readonly Label _paramDiffLabel;
        private readonly Button _applyParamsButton;
        private readonly Button _applyAndRunParamsButton;
        private readonly Button _rejectParamsButton;
        /// <summary>Apply patch to Grasshopper params only (queue for Design Run merge).</summary>
        private readonly Action<JObject>? _onApplyPatch;
        /// <summary>Apply patch and request one Design Run (Run input forced true once).</summary>
        private readonly Action<JObject>? _onApplyAndRunPatch;

        // Suggestions panel — populated after each agent turn.
        private readonly Panel _suggestionsPanel;
        private readonly Panel _suggestionButtonsContainer;
        private readonly Label _suggestionsHeaderLabel;

        // Selected reflection prompt — shown above the input until sent or dismissed.
        private readonly Panel _activeReflectionPanel;
        private readonly Label _activeReflectionQuestionLabel;
        private readonly Button _activeReflectionBackButton;
        private string? _activeReflectionPrompt;
        private string[] _lastSuggestionItems = Array.Empty<string>();

        private const string DefaultInputPlaceholder = "Type your message…";
        private const string AnswerInputPlaceholder  = "Type your answer…";

        // Clarification panel — structured multiple-choice prompt.
        private readonly Panel _clarificationPanel;
        private readonly Label _clarificationPromptLabel;
        private readonly Label _clarificationMetaLabel;
        private readonly Panel _clarificationOptionsContainer;
        private readonly Button _clarificationSubmitButton;
        private readonly Button _clarificationCancelButton;
        private readonly Dictionary<string, RadioButton> _clarificationSingleSelect = new Dictionary<string, RadioButton>();
        private readonly Dictionary<string, CheckBox> _clarificationMultiSelect = new Dictionary<string, CheckBox>();

        // Retry panel — shown after recoverable errors.
        private readonly Panel _retryPanel;
        private readonly Label _retryLabel;
        private readonly Button _retryButton;

        // Action timeline — accumulated tool actions for the current turn.
        private readonly List<ToolAction> _turnActions = new List<ToolAction>();

        // ─── Pending proposed params ─────────────────────────────────────────
        private JObject? _pendingProposedParams;
        private ClarificationPrompt? _pendingClarification;
        /// <summary>When true, the next POST /chat includes reset_session=true to clear server-side design history and insights.</summary>
        private bool _resetSessionOnNextSend;

        // ─── Public outputs ───────────────────────────────────────────────────

        /// <summary>
        /// The most recently accepted params patch from the assistant.
        /// Null if no params were proposed, or the user rejected all proposals.
        /// </summary>
        public JObject? ProposedParams { get; private set; }

        /// <summary>Full conversation transcript (user + assistant messages).</summary>
        public string Transcript => _chatArea?.Text ?? "";

        /// <summary>Staged JSON from the last assistant proposal (before Apply / Reject).</summary>
        internal JObject? PeekPendingStagedPatch()
        {
            if (_pendingProposedParams == null || _pendingProposedParams.Count == 0)
                return null;
            return (JObject)_pendingProposedParams.DeepClone();
        }

        /// <summary>Clear staged proposal after canvas Apply merged it into Grasshopper.</summary>
        public void DismissStagedProposedParams()
        {
            ProposedParams = null;
            HideParamDiff();
        }

        /// <summary>
        /// Bring this window to the foreground and focus the message input.
        /// Safe to call repeatedly (e.g., when the component Open input is pressed again).
        /// </summary>
        public void BringToFrontAndFocus()
        {
            try
            {
                if (WindowState == WindowState.Minimized)
                    WindowState = WindowState.Normal;
            }
            catch
            {
                // Best-effort restore; some platforms may not expose all states.
            }

            BringToFront();
            Focus();
            _inputBox.Focus();
        }

        // ─── Constructor ─────────────────────────────────────────────────────

        /// <summary>
        /// Create the chat dialog.
        /// </summary>
        /// <param name="mode">"design" or "results"</param>
        /// <param name="geometrySummary">Optional geometry summary text for prompt context.</param>
        /// <param name="sessionSeed">
        ///   Optional stable seed for session/history keying. When omitted, geometrySummary
        ///   is used as the seed to preserve legacy behavior.
        /// </param>
        /// <param name="currentParams">Current design params (design mode).</param>
        /// <param name="result">Current design result (results mode).</param>
        /// <param name="applicabilitySchema">
        ///   Optional compact applicability schema from GET /schema/applicability.
        ///   When provided, a method-eligibility banner is shown at the top of the dialog.
        /// </param>
        /// <param name="initialHistory">
        ///   Optional pre-loaded conversation history. When non-empty the proactive opening
        ///   analysis is skipped (the conversation is being resumed).
        /// </param>
        /// <param name="autoAnalyze">
        ///   When true and there is no initial history, the dialog fires an opening
        ///   analysis automatically on first show.
        /// </param>
        /// <param name="resultsSummary">
        ///   Optional short summary when <paramref name="mode"/> is <c>results</c> (e.g. pass/fail, utilization, counts).
        ///   Shown at the top of the chat and appended to <c>geometry_summary</c> for the model.
        /// </param>
        /// <param name="onApplyPatch">When set, Apply merges the JSON patch into the Unified Assistant / Design Run pipeline.</param>
        /// <param name="onApplyAndRunPatch">When set, Apply &amp; Run merges the patch and triggers one design run.</param>
        public ChatDialog(
            string mode,
            string geometrySummary,
            string? sessionSeed,
            DesignParamsData? currentParams,
            DesignResult? result,
            JObject? applicabilitySchema = null,
            List<JObject>? initialHistory = null,
            bool autoAnalyze = true,
            string? resultsSummary = null,
            Action<JObject>? onApplyPatch = null,
            Action<JObject>? onApplyAndRunPatch = null)
        {
            _mode              = mode;
            _baseUrl           = MenegrothConfig.LastServerUrl;
            _geometrySummary   = geometrySummary ?? "";
            _resultsSummary    = resultsSummary?.Trim() ?? "";
            _contextForApi     = BuildCombinedContext(_geometrySummary, _resultsSummary);
            _paramsJson        = currentParams?.ToJson();
            _applicabilitySchema = applicabilitySchema;
            _sessionId         = ComputeSessionId(string.IsNullOrWhiteSpace(sessionSeed) ? geometrySummary : sessionSeed);
            _autoAnalyze       = autoAnalyze;
            _onApplyPatch      = onApplyPatch;
            _onApplyAndRunPatch = onApplyAndRunPatch;

            Title       = mode == "design" ? "Design Assistant" : "Results Assistant";
            MinimumSize = new Size(660, 520);
            Size        = new Size(760, 660);
            Resizable   = true;

            // ── Chat area ───────────────────────────────────────────────────
            _chatArea = new TextArea
            {
                ReadOnly = true,
                Wrap     = true,
                Font     = new Font(FontFamilies.Monospace, 9.5f),
            };

            // ── Input row ────────────────────────────────────────────────────
            _inputBox = new TextBox { PlaceholderText = DefaultInputPlaceholder };
            _inputBox.KeyDown += (s, e) =>
            {
                if (e.Key == Keys.Enter && !e.Modifiers.HasFlag(Keys.Shift))
                {
                    e.Handled = true;
                    SendMessage();
                }
            };

            _sendButton = new Button { Text = "Send", Width = 70 };
            _sendButton.Click += (s, e) => SendMessage();

            var inputRow = new TableLayout
            {
                Spacing = new Size(5, 0),
                Rows    = { new TableRow(new TableCell(_inputBox, true), _sendButton) }
            };

            // ── Param diff panel ─────────────────────────────────────────────
            _paramDiffLabel = new Label
            {
                Wrap      = WrapMode.Word,
                TextColor = Color.FromArgb(0x33, 0x33, 0x00),
            };
            _applyParamsButton = new Button { Text = "Apply", Width = 72, ToolTip = "Merge patch into params (queue for Design Run on next run)" };
            _applyParamsButton.Click += OnApplyParamsClicked;
            _applyAndRunParamsButton = new Button { Text = "Apply & Run", Width = 100, ToolTip = "Merge patch and start one design run" };
            _applyAndRunParamsButton.Click += OnApplyAndRunParamsClicked;
            _rejectParamsButton = new Button { Text = "Reject", Width = 72 };
            _rejectParamsButton.Click += OnRejectParamsClicked;

            var diffButtons = new TableLayout
            {
                Spacing = new Size(5, 0),
                Rows    = { new TableRow(new TableCell(_paramDiffLabel, true), _applyParamsButton, _applyAndRunParamsButton, _rejectParamsButton) }
            };

            _paramDiffPanel = new Panel
            {
                BackgroundColor = Color.FromArgb(0xFF, 0xFF, 0xCC),
                Padding         = new Padding(8, 6),
                Content         = diffButtons,
                Visible         = false,
            };

            // ── Suggestions panel ─────────────────────────────────────────────
            _suggestionButtonsContainer = new Panel();
            _suggestionsHeaderLabel = new Label
            {
                Text      = "Pick a question to answer — it appears above your reply:",
                Font      = new Font(SystemFont.Label, 8.5f),
                TextColor = Color.FromArgb(0x44, 0x44, 0x88),
            };
            _suggestionsPanel = new Panel
            {
                BackgroundColor = Color.FromArgb(0xF0, 0xF4, 0xFF),
                Padding         = new Padding(8, 6),
                Content         = new TableLayout
                {
                    Rows =
                    {
                        new TableRow(_suggestionsHeaderLabel),
                        new TableRow(_suggestionButtonsContainer),
                    }
                },
                Visible = false,
            };

            // ── Active reflection prompt (replaces cards until sent or "different prompt") ──
            var activeReflectionHeader = new Label
            {
                Text      = "You're answering:",
                Font      = new Font(SystemFont.Label, 8.5f),
                TextColor = Color.FromArgb(0x22, 0x44, 0x66),
            };
            _activeReflectionQuestionLabel = new Label
            {
                Wrap      = WrapMode.Word,
                Font      = new Font(SystemFont.Label, 9f),
                TextColor = Color.FromArgb(0x11, 0x22, 0x44),
            };
            _activeReflectionBackButton = new Button { Text = "Choose a different prompt", Width = 200 };
            _activeReflectionBackButton.Click += (_, __) => OnBackToReflectionPromptsClicked();

            _activeReflectionPanel = new Panel
            {
                BackgroundColor = Color.FromArgb(0xE8, 0xF2, 0xFC),
                Padding         = new Padding(10, 8),
                Content         = new TableLayout
                {
                    Spacing = new Size(0, 6),
                    Rows =
                    {
                        new TableRow(activeReflectionHeader),
                        new TableRow(_activeReflectionQuestionLabel),
                        new TableRow(_activeReflectionBackButton),
                    }
                },
                Visible = false,
            };

            // ── Clarification panel ───────────────────────────────────────────
            _clarificationPromptLabel = new Label
            {
                Wrap      = WrapMode.Word,
                Font      = new Font(SystemFont.Label, 9f),
                TextColor = Color.FromArgb(0x22, 0x22, 0x55),
            };
            _clarificationMetaLabel = new Label
            {
                Wrap      = WrapMode.Word,
                Font      = new Font(SystemFont.Label, 8f),
                TextColor = Color.FromArgb(0x55, 0x55, 0x77),
            };
            _clarificationOptionsContainer = new Panel();
            _clarificationSubmitButton = new Button { Text = "Submit", Width = 80 };
            _clarificationSubmitButton.Click += OnClarificationSubmitClicked;
            _clarificationCancelButton = new Button { Text = "Cancel", Width = 80 };
            _clarificationCancelButton.Click += OnClarificationCancelClicked;

            _clarificationPanel = new Panel
            {
                BackgroundColor = Color.FromArgb(0xE8, 0xFB, 0xF2),
                Padding         = new Padding(8, 6),
                Content         = new TableLayout
                {
                    Spacing = new Size(0, 4),
                    Rows =
                    {
                        new TableRow(_clarificationPromptLabel),
                        new TableRow(_clarificationMetaLabel),
                        new TableRow(_clarificationOptionsContainer),
                        new TableRow(new TableLayout
                        {
                            Spacing = new Size(5, 0),
                            Rows = { new TableRow(_clarificationSubmitButton, _clarificationCancelButton, null) }
                        })
                    }
                },
                Visible = false,
            };

            // ── Retry panel ──────────────────────────────────────────────────
            _retryLabel = new Label
            {
                Wrap      = WrapMode.Word,
                TextColor = Color.FromArgb(0x88, 0x22, 0x22),
                Font      = new Font(SystemFont.Label, 8.5f),
            };
            _retryButton = new Button { Text = "Retry", Width = 70 };
            _retryButton.Click += OnRetryClicked;

            _retryPanel = new Panel
            {
                BackgroundColor = Color.FromArgb(0xFF, 0xEE, 0xEE),
                Padding         = new Padding(8, 6),
                Content         = new TableLayout
                {
                    Spacing = new Size(5, 0),
                    Rows    = { new TableRow(new TableCell(_retryLabel, true), _retryButton) }
                },
                Visible = false,
            };

            // ── Session toolbar ──────────────────────────────────────────────
            var newSessionButton = new Button { Text = "New Session", Width = 100 };
            newSessionButton.Click += OnNewSessionClicked;

            var clearHistoryButton = new Button { Text = "Clear History", Width = 100 };
            clearHistoryButton.Click += OnClearHistoryClicked;

            var sessionToolbar = new TableLayout
            {
                Spacing = new Size(5, 0),
                Rows    = { new TableRow(newSessionButton, clearHistoryButton, null) }
            };

            // ── Main layout ──────────────────────────────────────────────────
            var mainLayout = new TableLayout
            {
                Padding = new Padding(10),
                Spacing = new Size(0, 5),
            };

            mainLayout.Rows.Add(new TableRow(sessionToolbar));

            // Optional applicability banner at the top (design mode only).
            var banner = BuildApplicabilityBanner(applicabilitySchema);
            if (banner != null) mainLayout.Rows.Add(new TableRow(banner));

            mainLayout.Rows.Add(new TableRow(new TableCell(_chatArea)) { ScaleHeight = true });
            mainLayout.Rows.Add(new TableRow(_retryPanel));
            mainLayout.Rows.Add(new TableRow(_paramDiffPanel));
            mainLayout.Rows.Add(new TableRow(_clarificationPanel));
            mainLayout.Rows.Add(new TableRow(_suggestionsPanel));
            mainLayout.Rows.Add(new TableRow(_activeReflectionPanel));
            mainLayout.Rows.Add(new TableRow(inputRow));

            Content = mainLayout;

            var closeButton = new Button { Text = "Close", Width = 80 };
            closeButton.Click += (s, e) => Close();
            mainLayout.Rows.Add(new TableRow(new TableLayout
            {
                Spacing = new Size(5, 0),
                Rows = { new TableRow(null, closeButton) }
            }));

            Closed += (s, e) => _cts?.Cancel();

            // ── Load initial history ─────────────────────────────────────────
            if (initialHistory != null && initialHistory.Count > 0)
                LoadHistory(initialHistory);

            // ── Auto-analyze on open ─────────────────────────────────────────
            // Fire after layout is visible. Use AsyncInvoke so ShowModal returns first.
            bool hasHistory = initialHistory != null && initialHistory.Count > 0;
            if (_autoAnalyze && !hasHistory)
            {
                Shown += (s, e) =>
                {
                    Application.Instance.AsyncInvoke(() =>
                    {
                        if (_mode == "results" && !string.IsNullOrEmpty(_resultsSummary))
                            AppendChat("Results", _resultsSummary);
                        AppendChat("System", $"[New session — {_sessionId.Substring(0, 8)}]");
                        FireProactiveAnalysis();
                    });
                };
            }

            UpdateInputEnabled();
        }

        /// <summary>
        /// Merge building geometry text with a results digest for the single <c>geometry_summary</c> API field.
        /// </summary>
        private static string BuildCombinedContext(string geometrySummary, string resultsSummary)
        {
            if (string.IsNullOrWhiteSpace(resultsSummary))
                return geometrySummary ?? "";
            if (string.IsNullOrWhiteSpace(geometrySummary))
                return resultsSummary;
            return geometrySummary + "\n\n" + resultsSummary;
        }

        // ─── History loading ──────────────────────────────────────────────────

        private void LoadHistory(List<JObject> history)
        {
            ClarificationPrompt? unresolved = null;
            foreach (var msg in history)
            {
                var role    = msg["role"]?.ToString() ?? "user";
                var content = msg["content"]?.ToString() ?? "";
                if (string.IsNullOrWhiteSpace(content)) continue;
                _messages.Add(new ChatMessage(role, content));
                AppendChat(role == "user" ? "You" : "Assistant", content ?? "");

                if (role == "assistant" && TryExtractClarificationPrompt(content, out var parsed))
                {
                    unresolved = parsed;
                }
                else if (role == "user" && unresolved != null)
                {
                    // Any user turn after the prompt is treated as a clarification response.
                    unresolved = null;
                }
            }

            if (unresolved != null)
            {
                ShowClarificationPrompt(unresolved);
            }
        }

        // ─── Proactive opening analysis ───────────────────────────────────────

        private void FireProactiveAnalysis()
        {
            if (_isStreaming) return;

            var prompt = _mode == "design"
                ? "Please analyze the current building geometry and design parameters. Identify the most important structural considerations, note any compatibility issues between floor type and structural system, and give a brief orientation to the design space before we begin."
                : "Please analyze these design results. Summarize the key findings, highlight any failing or marginal elements, explain the governing limit states, and identify which parameters would have the greatest impact on improving the result.";

            AppendChat("System", "[Opening analysis]");
            _messages.Add(new ChatMessage("user", prompt));
            _ = StreamResponseAsync();
        }

        // ─── Message sending ──────────────────────────────────────────────────

        private void SendMessage()
        {
            if (HasMandatoryClarificationPending()) return;
            var text = _inputBox.Text?.Trim();
            if (string.IsNullOrEmpty(text) || _isStreaming) return;

            string outgoing;
            if (!string.IsNullOrEmpty(_activeReflectionPrompt))
            {
                outgoing = BuildReflectionOutgoingMessage(_activeReflectionPrompt, text);
                HideActiveReflectionPrompt();
            }
            else
            {
                outgoing = text;
            }

            _inputBox.Text = "";
            HideSuggestions();
            AppendChat("You", outgoing);
            _messages.Add(new ChatMessage("user", outgoing));
            _ = StreamResponseAsync();
        }

        /// <summary>
        /// User message sent to the LLM: ties the assistant's reflection prompt to the user's reply.
        /// </summary>
        private static string BuildReflectionOutgoingMessage(string prompt, string answer)
        {
            return "The assistant asked me to consider:\n" + prompt + "\n\nMy response:\n" + answer;
        }

        private async Task StreamResponseAsync()
        {
            _isStreaming = true;
            _turnActions.Clear();
            HideRetryPanel();
            UpdateInputEnabled();

            _cts = new CancellationTokenSource();

            var messagesArray = new JArray();
            foreach (var msg in _messages)
            {
                messagesArray.Add(new JObject
                {
                    ["role"]    = msg.Role,
                    ["content"] = msg.Content,
                });
            }

            var requestBody = new JObject
            {
                ["mode"]             = _mode,
                ["messages"]         = messagesArray,
                ["geometry_summary"] = _contextForApi,
                ["session_id"]       = _sessionId,
            };
            if (_paramsJson != null) requestBody["params"] = _paramsJson;
            if (_resetSessionOnNextSend)
            {
                requestBody["reset_session"] = true;
                _resetSessionOnNextSend = false;
            }

            DesignRunHttpClient.EnrichChatBodyWithGeometry(requestBody);

            var responseBuilder = new StringBuilder();
            bool hadError = false;
            AppendChat("Assistant", "");

            try
            {
                await DesignRunHttpClient.PostChatStreamAsync(
                    _baseUrl,
                    requestBody.ToString(Newtonsoft.Json.Formatting.None),
                    onToken: token =>
                    {
                        responseBuilder.Append(token);
                        Application.Instance.Invoke(() => AppendToLastMessage(token));
                    },
                    onError: error =>
                    {
                        hadError = true;
                        Application.Instance.Invoke(() =>
                        {
                            AppendToLastMessage($"\n[Error: {error}]");
                            ShowRetryPanel(error);
                        });
                    },
                    ct: _cts.Token,
                    onSummary: summary =>
                    {
                        Application.Instance.Invoke(() => HandleAgentTurnSummary(summary));
                    }
                );
            }
            catch (System.Net.Http.HttpRequestException)
            {
                hadError = true;
                var msg = "Could not reach the design server. Check that it is running.";
                Application.Instance.Invoke(() =>
                {
                    AppendToLastMessage($"\n[{msg}]");
                    ShowRetryPanel(msg);
                });
            }
            catch (OperationCanceledException)
            {
                // TaskCanceledException derives from OperationCanceledException. Only suppress retry UI when our CTS was cancelled (user closed dialog, etc.).
                if (_cts?.Token.IsCancellationRequested != true)
                {
                    hadError = true;
                    var msg = "Request timed out. The server may be busy with a design run.";
                    Application.Instance.Invoke(() =>
                    {
                        AppendToLastMessage($"\n[{msg}]");
                        ShowRetryPanel(msg);
                    });
                }
            }
            catch (Exception ex)
            {
                hadError = true;
                var msg = $"Unexpected error: {ex.Message}";
                Application.Instance.Invoke(() =>
                {
                    AppendToLastMessage($"\n[{msg}]");
                    ShowRetryPanel(msg);
                });
            }

            var fullResponse = responseBuilder.ToString();
            _messages.Add(new ChatMessage("assistant", fullResponse));

            if (!hadError)
            {
                // Allow param proposals in both design and results phases.
                // The unified assistant can stage updates regardless of whether
                // a result is already available.
                ExtractAndPresentProposedParams(fullResponse);
                if (_pendingClarification == null &&
                    TryExtractClarificationPrompt(fullResponse, out var fallbackPrompt) &&
                    fallbackPrompt != null)
                    ShowClarificationPrompt(fallbackPrompt);
            }

            _isStreaming = false;
            Application.Instance.Invoke(UpdateInputEnabled);
        }

        // ─── Agent turn summary ───────────────────────────────────────────────

        private void HandleAgentTurnSummary(JObject summary)
        {
            var questions = summary["suggested_next_questions"] as JArray;
            if (questions != null && questions.Count > 0)
            {
                var items = questions
                    .Select(q => q.ToString())
                    .Where(q => !string.IsNullOrWhiteSpace(q))
                    .ToArray();
                ShowSuggestions(items);
            }

            if (summary["clarification_prompt"] is JObject clarificationObj &&
                TryParseClarificationPrompt(clarificationObj, out var parsed) &&
                parsed != null)
            {
                ShowClarificationPrompt(parsed);
            }

            if (summary["tool_actions"] is JArray actionsArr && actionsArr.Count > 0)
            {
                foreach (var tok in actionsArr)
                {
                    if (tok is JObject actionObj)
                    {
                        _turnActions.Add(new ToolAction(
                            tool:      actionObj["tool"]?.ToString() ?? "unknown",
                            status:    actionObj["status"]?.ToString() ?? "ok",
                            elapsedMs: actionObj["elapsed_ms"]?.ToObject<int?>(),
                            summary:   actionObj["summary"]?.ToString()
                        ));
                    }
                }
                RenderActionTimeline();
            }
        }

        // ─── Param proposal ───────────────────────────────────────────────────

        private void ExtractAndPresentProposedParams(string response)
        {
            var match = Regex.Match(response, @"```(?:json)?\s*\n({[\s\S]*?})\s*\n```");
            if (!match.Success) return;

            try
            {
                var patch = JObject.Parse(match.Groups[1].Value);
                if (patch.Count == 0) return;
                _pendingProposedParams = patch;
                ShowParamDiff(patch);
            }
            catch
            {
                // Malformed JSON block — ignore
            }
        }

        private void ShowParamDiff(JObject proposed)
        {
            var sb = new StringBuilder();
            if (proposed.TryGetValue("_history_label", out var hl) && hl.Type == JTokenType.String)
            {
                var summary = hl.ToString().Trim();
                if (!string.IsNullOrEmpty(summary))
                    sb.Append("Summary: ").Append(summary).Append("  |  ");
            }

            sb.Append("Proposed changes: ");
            bool first = true;
            foreach (var prop in proposed.Properties())
            {
                if (string.Equals(prop.Name, "_history_label", StringComparison.Ordinal))
                    continue;
                if (!first) sb.Append("  |  ");
                first = false;

                // Try to find the current value to show old → new.
                var currentVal = _paramsJson?.SelectToken(prop.Name);
                if (currentVal != null)
                    sb.Append($"{prop.Name}: {currentVal} → {prop.Value}");
                else
                    sb.Append($"{prop.Name}: {prop.Value}");
            }

            Application.Instance.Invoke(() =>
            {
                _paramDiffLabel.Text = sb.ToString();
                _paramDiffPanel.Visible = true;
            });
        }

        private void HideParamDiff()
        {
            _pendingProposedParams = null;
            Application.Instance.Invoke(() => _paramDiffPanel.Visible = false);
        }

        private void OnApplyParamsClicked(object? sender, EventArgs e)
        {
            if (_pendingProposedParams == null || _pendingProposedParams.Count == 0)
                return;

            var patch = (JObject)_pendingProposedParams.DeepClone();
            if (_onApplyPatch != null)
            {
                _onApplyPatch.Invoke(patch);
                ProposedParams = null;
                HideParamDiff();
                AppendChat("System", "[Patch applied to Design Params / assistant output]");
            }
            else
            {
                ProposedParams = _pendingProposedParams;
                HideParamDiff();
                AppendChat("System", "[Proposed params accepted — toggle Apply on the Unified Assistant component to merge]");
            }
        }

        private void OnApplyAndRunParamsClicked(object? sender, EventArgs e)
        {
            if (_pendingProposedParams == null || _pendingProposedParams.Count == 0)
                return;

            var patch = (JObject)_pendingProposedParams.DeepClone();
            if (_onApplyAndRunPatch != null)
            {
                _onApplyAndRunPatch.Invoke(patch);
                ProposedParams = null;
                HideParamDiff();
                AppendChat("System", "[Patch applied — design run started]");
            }
            else
            {
                AppendChat("System", "[Apply & Run requires Unified Assistant wiring — use Apply on the component]");
            }
        }

        private void OnRejectParamsClicked(object? sender, EventArgs e)
        {
            HideParamDiff();
            AppendChat("System", "[Proposed params rejected]");
        }

        // ─── Suggestions UI ───────────────────────────────────────────────────

        private void ShowSuggestions(string[] questions)
        {
            if (questions.Length == 0)
            {
                HideSuggestions();
                return;
            }

            HideActiveReflectionPrompt();
            _lastSuggestionItems = questions;

            // Rebuild the button container with fresh buttons for this turn.
            var buttonLayout = new TableLayout { Spacing = new Size(5, 3) };
            var row = new TableRow();
            foreach (var question in questions)
            {
                var q = question; // capture for lambda
                var btn = new Button
                {
                    Text  = q,
                    Font  = new Font(SystemFont.Label, 8.5f),
                    Width = 200,
                };
                btn.Click += (s, e) => OnSuggestionClicked(q);
                row.Cells.Add(btn);
            }
            buttonLayout.Rows.Add(row);

            _suggestionButtonsContainer.Content = buttonLayout;
            _suggestionsPanel.Visible = true;
        }

        private void HideSuggestions()
        {
            Application.Instance.Invoke(() => _suggestionsPanel.Visible = false);
        }

        private void OnSuggestionClicked(string question)
        {
            if (_isStreaming) return;

            _activeReflectionPrompt = question;
            _activeReflectionQuestionLabel.Text = question;
            _activeReflectionPanel.Visible = true;
            _suggestionsPanel.Visible = false;

            _inputBox.Text = "";
            _inputBox.PlaceholderText = AnswerInputPlaceholder;
            _inputBox.Focus();
        }

        private void OnBackToReflectionPromptsClicked()
        {
            if (_isStreaming) return;
            HideActiveReflectionPrompt();
            if (_lastSuggestionItems.Length > 0)
                _suggestionsPanel.Visible = true;
        }

        /// <summary>
        /// Clears the selected reflection prompt strip and restores the default input placeholder.
        /// </summary>
        private void HideActiveReflectionPrompt()
        {
            _activeReflectionPrompt = null;
            _activeReflectionQuestionLabel.Text = "";
            _activeReflectionPanel.Visible = false;
            _inputBox.PlaceholderText = DefaultInputPlaceholder;
        }

        // ─── Clarification UI ────────────────────────────────────────────────

        private bool HasMandatoryClarificationPending()
        {
            return _pendingClarification != null &&
                   !string.IsNullOrWhiteSpace(_pendingClarification.RequiredFor);
        }

        private void UpdateInputEnabled()
        {
            bool canType = !_isStreaming && !HasMandatoryClarificationPending();
            _sendButton.Enabled = canType;
            _inputBox.Enabled = canType;
        }

        private void ShowClarificationPrompt(ClarificationPrompt prompt)
        {
            _pendingClarification = prompt;

            _clarificationPromptLabel.Text = prompt.Prompt;
            _clarificationMetaLabel.Text = BuildClarificationMeta(prompt);

            _clarificationSingleSelect.Clear();
            _clarificationMultiSelect.Clear();

            var optionsLayout = new TableLayout { Spacing = new Size(0, 3) };
            RadioButton? firstRadio = null;
            foreach (var option in prompt.Options)
            {
                if (prompt.AllowMultiple)
                {
                    var cb = new CheckBox { Text = option.Label };
                    _clarificationMultiSelect[option.Id] = cb;
                    optionsLayout.Rows.Add(new TableRow(cb));
                }
                else
                {
                    var rb = firstRadio == null ? new RadioButton() : new RadioButton(firstRadio);
                    if (firstRadio == null) firstRadio = rb;
                    rb.Text = option.Label;
                    _clarificationSingleSelect[option.Id] = rb;
                    optionsLayout.Rows.Add(new TableRow(rb));
                }
            }

            _clarificationOptionsContainer.Content = optionsLayout;
            _clarificationPanel.Visible = true;
            UpdateInputEnabled();
        }

        private static string BuildClarificationMeta(ClarificationPrompt prompt)
        {
            var parts = new List<string>();
            if (!string.IsNullOrWhiteSpace(prompt.RequiredFor))
                parts.Add($"Required for: {prompt.RequiredFor}");
            if (!string.IsNullOrWhiteSpace(prompt.Rationale))
                parts.Add(prompt.Rationale);
            return string.Join("  |  ", parts);
        }

        private void HideClarificationPrompt()
        {
            _pendingClarification = null;
            _clarificationPanel.Visible = false;
            _clarificationOptionsContainer.Content = null;
            _clarificationSingleSelect.Clear();
            _clarificationMultiSelect.Clear();
            UpdateInputEnabled();
        }

        private void OnClarificationSubmitClicked(object? sender, EventArgs e)
        {
            if (_isStreaming || _pendingClarification == null) return;

            var selected = new List<ClarificationOption>();
            if (_pendingClarification.AllowMultiple)
            {
                foreach (var opt in _pendingClarification.Options)
                {
                    if (_clarificationMultiSelect.TryGetValue(opt.Id, out var cb) && cb.Checked == true)
                        selected.Add(opt);
                }
            }
            else
            {
                foreach (var opt in _pendingClarification.Options)
                {
                    if (_clarificationSingleSelect.TryGetValue(opt.Id, out var rb) && rb.Checked == true)
                        selected.Add(opt);
                }
            }

            if (selected.Count == 0)
            {
                AppendChat("System", "[Select at least one option before submitting clarification.]");
                return;
            }

            var ids = string.Join(",", selected.Select(s => s.Id));
            var labels = string.Join(", ", selected.Select(s => s.Label));
            var responseText = $"[CLARIFICATION_RESPONSE id={_pendingClarification.Id} options={ids}] Clarification response: {labels}";

            HideClarificationPrompt();
            _inputBox.Text = "";
            HideActiveReflectionPrompt();
            HideSuggestions();
            AppendChat("You", responseText);
            _messages.Add(new ChatMessage("user", responseText));
            _ = StreamResponseAsync();
        }

        private void OnClarificationCancelClicked(object? sender, EventArgs e)
        {
            if (_pendingClarification == null) return;
            if (HasMandatoryClarificationPending())
            {
                AppendChat("System", "[This clarification is required before continuing.]");
                return;
            }

            AppendChat("System", "[Clarification dismissed]");
            HideClarificationPrompt();
        }

        private static bool TryExtractClarificationPrompt(string text, out ClarificationPrompt? prompt)
        {
            prompt = null;
            var match = Regex.Match(
                text,
                @"---CLARIFY---\s*(\{[\s\S]*?\})\s*---END-CLARIFY---",
                RegexOptions.Multiline);
            if (!match.Success) return false;

            try
            {
                var parsed = JObject.Parse(match.Groups[1].Value);
                return TryParseClarificationPrompt(parsed, out prompt);
            }
            catch
            {
                return false;
            }
        }

        private static bool TryParseClarificationPrompt(JObject obj, out ClarificationPrompt? prompt)
        {
            prompt = null;
            var promptText = obj["prompt"]?.ToString();
            var optionsArr = obj["options"] as JArray;
            if (string.IsNullOrWhiteSpace(promptText) || optionsArr == null || optionsArr.Count == 0)
                return false;

            var options = new List<ClarificationOption>();
            int fallbackIdx = 1;
            foreach (var tok in optionsArr)
            {
                if (tok is JObject optObj)
                {
                    var id = optObj["id"]?.ToString();
                    var label = optObj["label"]?.ToString();
                    if (string.IsNullOrWhiteSpace(label)) continue;
                    if (string.IsNullOrWhiteSpace(id)) id = $"opt_{fallbackIdx}";
                    options.Add(new ClarificationOption(id ?? $"opt_{fallbackIdx}", label ?? ""));
                }
                else
                {
                    var label = tok?.ToString();
                    if (string.IsNullOrWhiteSpace(label)) continue;
                    options.Add(new ClarificationOption($"opt_{fallbackIdx}", label ?? ""));
                }
                fallbackIdx++;
            }
            if (options.Count == 0) return false;

            prompt = new ClarificationPrompt(
                id: obj["id"]?.ToString() ?? "clarify",
                prompt: promptText ?? "",
                options: options,
                allowMultiple: obj["allow_multiple"]?.ToObject<bool>() ?? false,
                rationale: obj["rationale"]?.ToString(),
                requiredFor: obj["required_for"]?.ToString());
            return true;
        }

        // ─── Retry panel ─────────────────────────────────────────────────────────

        private void ShowRetryPanel(string errorMessage)
        {
            _retryLabel.Text = errorMessage;
            _retryPanel.Visible = true;
        }

        private void HideRetryPanel()
        {
            _retryPanel.Visible = false;
            _retryLabel.Text = "";
        }

        private void OnRetryClicked(object? sender, EventArgs e)
        {
            if (_isStreaming) return;
            HideRetryPanel();

            if (_messages.Count > 0 && _messages[_messages.Count - 1].Role == "assistant")
                _messages.RemoveAt(_messages.Count - 1);

            _ = StreamResponseAsync();
        }

        // ─── Action timeline ──────────────────────────────────────────────────

        private void RenderActionTimeline()
        {
            if (_turnActions.Count == 0) return;
            var parts = _turnActions.Select(a => a.ToString());
            var strip = "[" + string.Join(" -> ", parts) + "]";
            Application.Instance.Invoke(() => AppendChat("Actions", strip));
        }

        // ─── Session controls ──────────────────────────────────────────────────

        private async void OnNewSessionClicked(object? sender, EventArgs e)
        {
            if (_isStreaming) return;

            await DesignRunHttpClient.DeleteChatHistoryAsync(_baseUrl, _sessionId);

            _messages.Clear();
            _turnActions.Clear();
            _chatArea.Text = "";
            _pendingProposedParams = null;
            HideParamDiff();
            HideClarificationPrompt();
            HideSuggestions();
            HideActiveReflectionPrompt();
            HideRetryPanel();

            AppendChat("System", "[Session cleared]");
            FireProactiveAnalysis();
        }

        /// <summary>
        /// Clear all server-side session state: chat history, design history,
        /// and session insights. The next agent turn starts completely fresh
        /// with no memory of prior designs or conversations.
        /// </summary>
        private async void OnClearHistoryClicked(object? sender, EventArgs e)
        {
            if (_isStreaming) return;

            await DesignRunHttpClient.DeleteChatHistoryAsync(_baseUrl, _sessionId);

            _messages.Clear();
            _turnActions.Clear();
            _chatArea.Text = "";
            _pendingProposedParams = null;
            _resetSessionOnNextSend = true;
            HideParamDiff();
            HideClarificationPrompt();
            HideSuggestions();
            HideActiveReflectionPrompt();
            HideRetryPanel();

            AppendChat("System", "[History cleared — design history and insights will reset on next message]");
            FireProactiveAnalysis();
        }

        // ─── Applicability banner ─────────────────────────────────────────────

        private static Control? BuildApplicabilityBanner(JObject? schema)
        {
            if (schema == null) return null;

            try
            {
                var methodRules = schema["rules"]?["floor_options.method"] as JObject;
                if (methodRules == null) return null;

                var sb = new StringBuilder("  Method eligibility — ");
                bool first = true;
                foreach (var prop in methodRules.Properties())
                {
                    if (!first) sb.Append("   |   ");
                    first = false;

                    var hardChecks = prop.Value["hard_checks"] as JArray;
                    int hard = hardChecks?.Count ?? 0;
                    var codeBasis = prop.Value["code_basis"]?.ToString() ?? "";
                    sb.Append($"{prop.Name}: {hard} hard checks");
                    if (!string.IsNullOrEmpty(codeBasis))
                        sb.Append($" ({codeBasis})");
                }

                return new Panel
                {
                    BackgroundColor = Color.FromArgb(0xE8, 0xF0, 0xFF),
                    Padding         = new Padding(8, 5),
                    Content         = new Label
                    {
                        Text      = sb.ToString(),
                        TextColor = Color.FromArgb(0x1A, 0x3A, 0x6A),
                        Font      = new Font(SystemFont.Label, 8.5f),
                    },
                };
            }
            catch
            {
                return null;
            }
        }

        // ─── Chat area helpers ────────────────────────────────────────────────

        private void AppendChat(string role, string text)
        {
            if (_chatArea.Text.Length > 0)
                _chatArea.Append("\n\n");
            _chatArea.Append($"[{role}]\n{text}");
        }

        private void AppendToLastMessage(string text)
        {
            _chatArea.Append(text);
        }

        // ─── Session ID ────────────────────────────────────────────────────────

        /// <summary>
        /// Derive a stable, short session identifier from the geometry summary.
        /// Same geometry → same ID, enabling history persistence across dialog re-opens.
        /// </summary>
        private static string ComputeSessionId(string? input)
        {
            if (string.IsNullOrEmpty(input)) return Guid.NewGuid().ToString("N").Substring(0, 16);
            using var sha = SHA256.Create();
            var bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(input));
            return BitConverter.ToString(bytes).Replace("-", "").Substring(0, 16).ToLowerInvariant();
        }

        // ─── Inner type ───────────────────────────────────────────────────────

        private sealed class ClarificationOption
        {
            public string Id { get; }
            public string Label { get; }
            public ClarificationOption(string id, string label)
            {
                Id = id;
                Label = label;
            }
        }

        private sealed class ClarificationPrompt
        {
            public string Id { get; }
            public string Prompt { get; }
            public List<ClarificationOption> Options { get; }
            public bool AllowMultiple { get; }
            public string? Rationale { get; }
            public string? RequiredFor { get; }

            public ClarificationPrompt(
                string id,
                string prompt,
                List<ClarificationOption> options,
                bool allowMultiple,
                string? rationale,
                string? requiredFor)
            {
                Id = id;
                Prompt = prompt;
                Options = options;
                AllowMultiple = allowMultiple;
                Rationale = rationale;
                RequiredFor = requiredFor;
            }
        }

        private sealed class ChatMessage
        {
            public string Role    { get; }
            public string Content { get; }
            public ChatMessage(string role, string content) { Role = role; Content = content; }
        }

        private sealed class ToolAction
        {
            public string Tool { get; }
            public string Status { get; }
            public int? ElapsedMs { get; }
            public string? Summary { get; }

            public ToolAction(string tool, string status, int? elapsedMs = null, string? summary = null)
            {
                Tool = tool;
                Status = status;
                ElapsedMs = elapsedMs;
                Summary = summary;
            }

            public override string ToString()
            {
                var s = Tool;
                if (ElapsedMs.HasValue) s += $" ({ElapsedMs.Value / 1000.0:F1}s)";
                if (Status == "ok")
                {
                    if (!string.IsNullOrEmpty(Summary)) s += $" -> {Summary}";
                }
                else
                {
                    s += $" [{Status}]";
                    if (!string.IsNullOrEmpty(Summary)) s += $": {Summary}";
                }
                return s;
            }
        }
    }
}
