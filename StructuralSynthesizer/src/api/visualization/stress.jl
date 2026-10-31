"""Compute per-face analytical scalars from ShellInternalForces and append to arrays.
Signed quantities preserve physical meaning (+ tension/sagging, − compression/hogging)."""
function _append_shell_analytical!(face_bending, face_membrane, face_shear,
                                    face_vm, face_surf, shell, u_global, sif_ws)
    sif = Asap.ShellInternalForces(shell, u_global, sif_ws)
    t = shell.thickness  # [m]

    # Signed dominant principal bending moment (+ sagging, − hogging)
    pm = Asap.principal_moments(sif)
    push!(face_bending, _signed_extremum(pm.M1, pm.M2))

    # Signed dominant principal membrane force (+ tension, − compression)
    pf = Asap.principal_forces(sif)
    push!(face_membrane, _signed_extremum(pf.N1, pf.N2))

    # Transverse shear resultant: √(Qxz² + Qyz²) — always ≥ 0
    push!(face_shear, sqrt(sif.Qxz^2 + sif.Qyz^2))

    # Von Mises at top (+t/2) and bottom (-t/2) surfaces — always ≥ 0
    vm_top = Asap.von_mises_stress(sif, t / 2, t)
    vm_bot = Asap.von_mises_stress(sif, -t / 2, t)
    push!(face_vm, max(vm_top, vm_bot))

    # Signed dominant principal stress at top/bottom (+ tension, − compression)
    surf = Asap.max_surface_stresses(sif, t)
    σ_top = _signed_principal_stress(surf.top.σxx, surf.top.σyy, surf.top.τxy)
    σ_bot = _signed_principal_stress(surf.bottom.σxx, surf.bottom.σyy, surf.bottom.τxy)
    push!(face_surf, _signed_extremum(σ_top, σ_bot))

    return nothing
end

"""Return the value with the largest absolute magnitude, preserving sign."""
_signed_extremum(a, b) = abs(a) >= abs(b) ? a : b

"""Signed dominant principal stress from a 2D stress state (σxx, σyy, τxy).
Returns the principal stress (σ1 or σ2) with the largest absolute value, keeping sign."""
function _signed_principal_stress(σxx, σyy, τxy)
    avg = (σxx + σyy) / 2
    R = sqrt(((σxx - σyy) / 2)^2 + τxy^2)
    σ1 = avg + R
    σ2 = avg - R
    return _signed_extremum(σ1, σ2)
end

