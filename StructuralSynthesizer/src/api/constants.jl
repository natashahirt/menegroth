"""
    API_UNIT_ALIASES

Accepted input spellings for coordinate units.
"""
const API_UNIT_ALIASES = (
    "feet",
    "ft",
    "inches",
    "in",
    "meters",
    "m",
    "millimeters",
    "mm",
    "centimeters",
    "cm",
)

"""Accepted floor-system type strings for API input."""
const API_FLOOR_TYPES = ("flat_plate", "flat_slab", "one_way", "vault")

"""Accepted floor analysis method strings for API input."""
const API_FLOOR_ANALYSIS_METHODS = ("DDM", "DDM_SIMPLIFIED", "EFM", "EFM_HARDY_CROSS", "FEA")

"""Accepted floor deflection limit strings for API input."""
const API_DEFLECTION_LIMITS = ("L_240", "L_360", "L_480")

"""Accepted punching strategy strings for API input."""
const API_PUNCHING_STRATEGIES = ("grow_columns", "reinforce_last", "reinforce_first")

"""Accepted primary column type strings for API input."""
const API_COLUMN_TYPES = ("rc_rect", "rc_circular", "steel_w", "steel_hss", "steel_pipe", "pixelframe")

"""Accepted steel column catalog strings."""
const API_STEEL_COLUMN_CATALOGS = ("compact_only", "preferred", "all")

"""Accepted RC rectangular column catalog strings."""
const API_RC_RECT_COLUMN_CATALOGS = ("standard", "square", "rectangular", "low_capacity", "high_capacity", "all")

"""Accepted RC circular column catalog strings."""
const API_RC_CIRCULAR_COLUMN_CATALOGS = ("standard", "low_capacity", "high_capacity", "all")

"""Accepted primary beam type strings for API input."""
const API_BEAM_TYPES = ("steel_w", "steel_hss", "rc_rect", "rc_tbeam", "pixelframe")

"""Accepted beam catalog strings."""
const API_BEAM_CATALOGS = ("standard", "small", "large", "xlarge", "all", "custom")

"""Accepted PixelFrame f'c preset strings."""
const API_PIXELFRAME_FC_PRESETS = ("standard", "low", "high", "extended", "custom")

"""Accepted sizing strategy strings for beam/column solvers."""
const API_SIZING_STRATEGIES = ("discrete", "nlp")

"""Accepted optimization objective strings."""
const API_OPTIMIZE_FOR = ("weight", "carbon", "cost")

"""Accepted foundation strategy strings."""
const API_FOUNDATION_STRATEGIES = ("auto", "auto_strip_spread", "all_spread", "all_strip", "mat")

"""Accepted foundation mat analysis method strings."""
const API_MAT_ANALYSIS_METHODS = ("rigid", "shukla", "winkler")

"""Accepted API unit_system strings."""
const API_UNIT_SYSTEMS = ("imperial", "metric")

"""Accepted API visualization detail strings."""
const API_VISUALIZATION_DETAILS = ("minimal", "full")

"""Return comma-separated documentation string for accepted string constants."""
_accepted_doc(values::Tuple) = join(values, ", ")
