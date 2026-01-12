abstract type AbstractMaterial end
abstract type AbstractDesignCode end

abstract type AbstractSection end

# Base types for structural modeling
abstract type AbstractStructuralSynthesizer end
abstract type AbstractBuildingSkeleton <: AbstractStructuralSynthesizer end
abstract type AbstractBuildingStructure <: AbstractStructuralSynthesizer end
