# =============================================================================
# Abstract Types for Structural Engineering
# =============================================================================
# Base types for materials, design codes, sections, and building models.

# =============================================================================
# Materials
# =============================================================================

"""Base type for all structural materials (Steel, Concrete, Timber, etc.)"""
abstract type AbstractMaterial end

export AbstractMaterial

# =============================================================================
# Design Codes
# =============================================================================

"""Base type for design code implementations (AISC, ACI, NDS, etc.)"""
abstract type AbstractDesignCode end

export AbstractDesignCode

# =============================================================================
# Sections
# =============================================================================

"""Base type for cross-sections (W shapes, HSS, RC columns, etc.)"""
abstract type AbstractSection end

export AbstractSection

# =============================================================================
# Building Models
# =============================================================================

"""Base type for structural synthesizer components."""
abstract type AbstractStructuralSynthesizer end

"""Base type for building skeletons (geometry only)."""
abstract type AbstractBuildingSkeleton <: AbstractStructuralSynthesizer end

"""Base type for building structures (geometry + sizing)."""
abstract type AbstractBuildingStructure <: AbstractStructuralSynthesizer end

export AbstractStructuralSynthesizer, AbstractBuildingSkeleton, AbstractBuildingStructure

# =============================================================================
# Member Types (for optimization interface)
# =============================================================================

"""Base type for load demand specifications."""
abstract type AbstractDemand end

"""Base type for member geometry specifications."""
abstract type AbstractMemberGeometry end

export AbstractDemand, AbstractMemberGeometry