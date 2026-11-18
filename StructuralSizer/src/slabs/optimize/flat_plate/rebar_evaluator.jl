# ==============================================================================
# Internal: Rebar Evaluation for a Given Bar Size
# ==============================================================================

"""
    _evaluate_rebar_for_size(p, moment_results, h, d, bar_size, c, unbal_mom_y) -> NamedTuple

Design all strip reinforcement using a specific bar size and return
total steel area + the positive-column-strip As (for deflection check).
`c` is the square NLP column size; `unbal_mom_y` is the perpendicular-axis
unbalanced moment (not stored on `MomentAnalysisResult`). Transfer `As`
from `governing_transfer_reinforcement` is added; Inf is infeasible.
"""
function _evaluate_rebar_for_size(p::FlatPlateNLPProblem, moment_results, h, d, bar_size,
                                  c, unbal_mom_y)
    l2 = moment_results.l2
    cs_w = l2 / 2   # column strip width
    ms_w = l2 / 2   # middle strip width

    # ACI 318-11 §13.6.4/.6 transverse distribution
    strip_designs = [
        # (Mu,                                    width,  label)
        (1.00 * moment_results.M_neg_ext, cs_w, :cs_ext_neg),
        (0.60 * moment_results.M_pos,     cs_w, :cs_pos),
        (0.75 * moment_results.M_neg_int, cs_w, :cs_int_neg),
        (0.40 * moment_results.M_pos,     ms_w, :ms_pos),
        (0.25 * moment_results.M_neg_int, ms_w, :ms_int_neg),
    ]

    total_As = 0.0u"inch^2"
    As_pos_cs = 0.0u"inch^2"

    for (Mu, width, label) in strip_designs
        As_reqd  = required_reinforcement(Mu, width, d, p.fc, p.fy; εt_min = tension_controlled_strain(p.fy))
        # Section inadequate — return Inf to signal infeasible point
        if isinf(As_reqd)
            return (total_As=Inf*u"inch^2", As_pos_cs=Inf*u"inch^2")
        end
        As_min   = minimum_reinforcement(width, h, p.fy)
        As_design = max(As_reqd, As_min)

        bars = select_bars_for_size(As_design, width, bar_size)
        total_As += bars.As_provided

        if label == :cs_pos
            As_pos_cs = bars.As_provided
        end
    end

    # ACI 318-11 §13.5.3.1 (corpus: aci-318-11, page 250): fraction of
    # unbalanced moment transferred by flexure. Inf = section_inadequate
    # (same sentinel as `_run_final_design`). Square `c` matches evaluate's
    # col_proxy — punching swap is a no-op; transfer As was the miss.
    n_col = length(p.column_positions)
    for i in 1:n_col
        gov = governing_transfer_reinforcement(
            moment_results.unbalanced_moments[i], unbal_mom_y[i],
            c, c, h, d, p.fc, p.fy;
            position = p.column_positions[i],
            free_edge_parallel = :c2)
        if transfer_section_inadequate(gov.As)
            return (total_As=Inf*u"inch^2", As_pos_cs=Inf*u"inch^2")
        end
        total_As += gov.As
    end

    return (total_As=total_As, As_pos_cs=As_pos_cs)
end

