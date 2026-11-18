# =============================================================================
# API Deserialize — JSON input → BuildingSkeleton + DesignParameters
# =============================================================================

"""
    parse_unit(unit_str::String) -> Unitful.FreeUnits

Convert a JSON unit string to a Unitful unit. Throws `ArgumentError` for
unrecognised strings.
"""
function parse_unit(unit_str::String)
    s = lowercase(strip(unit_str))
    s in ("feet", "ft")          && return u"ft"
    s in ("inches", "in")        && return u"inch"
    s in ("meters", "m")         && return u"m"
    s in ("millimeters", "mm")   && return u"mm"
    s in ("centimeters", "cm")   && return u"cm"
    throw(ArgumentError(
        "Unknown unit \"$unit_str\". " *
        "Accepted: $(_accepted_doc(API_UNIT_ALIASES))"))
end

# =============================================================================
