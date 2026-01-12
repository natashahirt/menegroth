# AISC W-Shape Catalog
# Loads from AISC shapes database and creates ISymmSection instances

const W_CATALOG = Dict{String, ISymmSection}()

"""Load W shapes from AISC CSV into catalog."""
function load_w_catalog!()
    csv_path = joinpath(@__DIR__, "data/aisc-shapes-v15.csv")
    
    for row in CSV.File(csv_path)
        row.Type == "W" || continue
        
        # Skip if missing geometry
        (ismissing(row.d) || ismissing(row.bf) || ismissing(row.tw) || ismissing(row.tf)) && continue
        
        name = string(row.AISC_Manual_Label)
        
        # Database uses imperial units (inches)
        d  = row.d * u"inch"
        bf = row.bf * u"inch"
        tw = row.tw * u"inch"
        tf = row.tf * u"inch"
        
        W_CATALOG[name] = ISymmSection(d, bf, tw, tf; name=name)
    end
    
    @debug "Loaded $(length(W_CATALOG)) W sections"
end

"""
    W(name::String)

Get W section by AISC name (e.g., "W10X22").
Returns ISymmSection with computed properties.
"""
function W(name::String)
    isempty(W_CATALOG) && load_w_catalog!()
    haskey(W_CATALOG, name) || error("W section '$name' not found in AISC database")
    return W_CATALOG[name]
end

"""List all available W section names."""
W_names() = (isempty(W_CATALOG) && load_w_catalog!(); collect(keys(W_CATALOG)))

"""Get all W sections as a collection."""
all_W() = (isempty(W_CATALOG) && load_w_catalog!(); collect(values(W_CATALOG)))
