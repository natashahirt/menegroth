---
id: deci-0fd1b15d
type: decision
project: menegroth
parent_id: plan-02c6d260
title: Eq. 12.8-13 is the sum over every level, i = 1 to n
node_label: 12.8-13 usual sum
tags: asce-7-22,asce-7-16,phase-6,corpus
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2b499c02
created_at: '2026-10-23T22:52:31.363828+00:00'
updated_at: '2026-10-23T22:52:31.363828+00:00'
---
ASCE 7-22 Eq. 12.8-13 (PDF page 186) prints i=1 above the summation sign and n below it. Commentary Figure C12.8-3 and ASCE 7-16 Eq. 12.8-12 (source_id asce-7-16, PDF page 157, glyph-confirmed) both print n above and i=1 below. The user chose the usual order. Code must quote the printed 7-22 form and mark the reading as engineering judgment. Manifest entry asce-7-22-12.8.3 is now accepted.

Edition comparison, for using 7-16 worked examples as oracles. Seismic: 7-16 Eqs. 12.8-2 to 12.8-6 match 7-22 Method 2 (Eqs. 12.8-3 to 12.8-7). Each 7-16 number is one lower. 7-16 has no Method 1 (Sa). The Ax, drift amplification, and theta_max equations match. 7-16 theta uses P Delta Ie / (V hsx Cd), while 7-22 Eq. 12.8-18 is (Px/hsx)/(Vx/Delta_xe). 7-16 drift is Cd delta_xe / Ie, while 7-22 adds delta_di. Wind differs: 7-16 Eq. 26.10-1 puts Kd inside qz (0.00256 Kz Kzt Kd Ke V^2), and 7-16 Eq. 27.3-1 is p = qGCp - qi(GCpi) with no Kd. 7-22 moves Kd into the pressure equation.
