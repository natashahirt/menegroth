"""Supertype for all structural materials (steel, concrete, timber, etc.)."""
abstract type AbstractMaterial end

"""Supertype for design code checkers (AISC, ACI, NDS, Eurocode, etc.)."""
abstract type AbstractDesignCode end

"""Supertype for all cross-section types (I-sections, HSS, rebar, glulam, etc.)."""
abstract type AbstractSection end

"""Supertype for structural-system containers (skeleton + structure)."""
abstract type AbstractStructuralSynthesizer end

"""Geometric and topological representation of a building (vertices, edges, faces)."""
abstract type AbstractBuildingSkeleton <: AbstractStructuralSynthesizer end

"""Analytical layer wrapping a skeleton: cells, slabs, members, foundations."""
abstract type AbstractBuildingStructure <: AbstractStructuralSynthesizer end
