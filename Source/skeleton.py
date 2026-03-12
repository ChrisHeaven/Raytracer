#!/usr/bin/env python3
"""
Optimized Cornell Box Ray Tracer (v3 — row-vectorized)

Speed:
  - Processes an entire pixel row in one numpy batch (vectorized across columns)
  - multiprocessing.Pool for true multi-core parallelism (4 workers)
  - Vectorized Möller-Trumbore: N_pixels × N_triangles in a single broadcast

Quality:
  - 4×4 stratified supersampling (16 spp)
  - 32 soft-shadow samples

Output: screenshot.bmp (300×300 RGB)
"""

import numpy as np
import math
import time
import multiprocessing as mp
from PIL import Image

# ---------------------------------------------------------------------------
SCREEN_WIDTH  = 300
SCREEN_HEIGHT = 300
FOCAL         = -0.5
F_LEN         = 1.0
YAW           = 0.0
CAMERA_Z      = -3.0

LIGHT_POS     = np.array([0.0, -0.5, -0.7])
LIGHT_COLOUR  = np.full(3, 14.0)
INDIRECT      = np.full(3, 0.5)

AA_SPP        = 4      # N×N stratified grid → N² spp
SHADOW_N      = 32     # soft-shadow ray count
SHADOW_R      = 0.03   # soft-shadow jitter radius

# Thin-lens depth of field
# Lens plane is at z=-2.0, focal plane at z=FOCAL=-0.5 (focus distance=1.5).
# APERTURE controls blur: 0 = pinhole (no DoF); larger → more blur.
# At APERTURE=0.04: back wall (z≈+1) gets ~12px CoC, blocks (z≈-0.5) stay sharp.
APERTURE      = 0.04   # thin-lens aperture radius in screen-space units

# Front-plane sentinel (C++ constant)
_FV0 = np.array([-0.76, -0.87, -1.0])
_FE1 = np.array([ 0.00,  1.87,  0.0])
_FE2 = np.array([ 2.07,  1.87,  0.0])


# ---------------------------------------------------------------------------
# MODEL

def _tv(p, L=555.0):
    p = np.asarray(p, dtype=np.float64) * 2.0 / L - 1.0
    p[0] *= -1.0; p[1] *= -1.0
    return p


def load_test_model():
    L = 555.0
    colors = {
        'red':    [0.75,0.15,0.15], 'yellow': [0.75,0.75,0.15],
        'green':  [0.15,0.75,0.15], 'cyan':   [0.15,0.75,0.75],
        'blue':   [0.15,0.15,0.75], 'purple': [0.75,0.15,0.75],
        'white':  [0.75,0.75,0.75],
    }
    raw = []
    def tri(a,b,c,col): raw.append((_tv(a,L),_tv(b,L),_tv(c,L),np.array(colors[col])))
    A=[L,0,0];B=[0,0,0];C=[L,0,L];D=[0,0,L];E=[L,L,0];F=[0,L,0];G=[L,L,L];H=[0,L,L]
    tri(C,B,A,'green'); tri(C,D,B,'green')
    tri(A,E,C,'purple'); tri(C,E,G,'purple')
    tri(F,B,D,'yellow'); tri(H,F,D,'yellow')
    tri(E,F,G,'cyan');  tri(F,H,G,'cyan')
    tri(G,D,C,'white'); tri(G,H,D,'white')
    A=[290,0,114];B=[130,0,65];C=[240,0,272];D=[82,0,225]
    E=[290,165,114];F=[130,165,65];G=[240,165,272];H=[82,165,225]
    for v0,v1,v2 in [(E,B,A),(E,F,B),(F,D,B),(F,H,D),(H,C,D),(H,G,C),(G,E,C),(E,A,C),(G,F,E),(G,H,F)]:
        tri(v0,v1,v2,'red')
    A=[423,0,247];B=[265,0,296];C=[472,0,406];D=[314,0,456]
    E=[423,330,247];F=[265,330,296];G=[472,330,406];H=[314,330,456]
    for v0,v1,v2 in [(E,B,A),(E,F,B),(F,D,B),(F,H,D),(H,C,D),(H,G,C),(G,E,C),(E,A,C),(G,F,E),(G,H,F)]:
        tri(v0,v1,v2,'blue')

    V0 = np.array([r[0] for r in raw])
    E1 = np.array([r[1]-r[0] for r in raw])
    E2 = np.array([r[2]-r[0] for r in raw])
    CO = np.array([r[3] for r in raw])
    NR = np.zeros_like(V0)
    for i in range(len(raw)):
        n = np.cross(E2[i], E1[i]); ln = np.linalg.norm(n)
        NR[i] = n/ln if ln>1e-10 else n
    return V0, E1, E2, NR, CO


# ---------------------------------------------------------------------------
# VECTORIZED INTERSECT  — P rays vs N triangles  → shape (P, N)

def _batch_PxN(origs, dirs, V0, E1, E2, min_t=0.03):
    """
    origs: (P,3), dirs: (P,3)
    V0,E1,E2: (N,3)
    Returns valid (P,N) bool, t (P,N) float
    """
    # pvec[p,n,:] = cross(dirs[p], E2[n])
    pvec = np.cross(dirs[:,None,:], E2[None,:,:])          # (P,N,3)
    det  = (E1[None,:,:] * pvec).sum(axis=2)               # (P,N)
    valid = np.abs(det) > 1e-6
    safe_det = np.where(valid, det, 1.0)
    inv_det  = 1.0 / safe_det

    tvec = origs[:,None,:] - V0[None,:,:]                  # (P,N,3)
    u    = (tvec * pvec).sum(axis=2) * inv_det             # (P,N)
    valid &= (u >= 0.0) & (u <= 1.0)

    qvec = np.cross(tvec, E1[None,:,:])                    # (P,N,3)
    v    = (dirs[:,None,:] * qvec).sum(axis=2) * inv_det   # (P,N)
    valid &= (v >= 0.0) & ((u + v) <= 1.0)

    t = (E2[None,:,:] * qvec).sum(axis=2) * inv_det        # (P,N)
    valid &= (t > min_t)
    return valid, t


def _batch_1xN(orig, d, V0, E1, E2, min_t=0.03):
    """Single ray vs N triangles. Returns valid(N,), t(N,)."""
    origs = orig[None,:]
    dirs  = d[None,:]
    v,t   = _batch_PxN(origs, dirs, V0, E1, E2, min_t)
    return v[0], t[0]


# ---------------------------------------------------------------------------
# SCENE HIT — vectorized over P rays

def _scene_hit_batch(origs, dirs, V0, E1, E2, CO, is_light):
    """
    origs,dirs: (P,3)
    Returns:
      hit       (P,)  bool
      tri_idx   (P,)  int
      t_val     (P,)  float
      positions (P,3)
      colours   (P,3)
      m_tri_idx (P,)  int   — mirror surface tri
      m_pos     (P,3)
    """
    P = len(origs)

    # Front-plane clipping (vectorised single-triangle test)
    fv, _ = _batch_PxN(origs, dirs,
                        _FV0[None,:], _FE1[None,:], _FE2[None,:], min_t=0.0)
    hits_front = fv[:,0]    # (P,)

    # Full-scene valid mask: (P, Ntri)
    N   = len(V0)
    N10 = 10
    valid_full, t_full = _batch_PxN(origs, dirs, V0, E1, E2)    # (P,N)

    # For primary rays that missed front plane, mask off triangles > 9
    if not is_light:
        mask_extra = np.zeros((P, N), dtype=bool)
        mask_extra[:, :N10] = True
        mask_extra[hits_front] = True    # rows that hit front plane → all tris
        valid_full &= mask_extra

    INF = np.inf
    t_masked = np.where(valid_full, t_full, INF)    # (P,N)
    any_hit   = valid_full.any(axis=1)              # (P,)

    tri_idx  = t_masked.argmin(axis=1).astype(int)  # (P,)
    t_val    = t_full[np.arange(P), tri_idx]        # (P,)
    positions = origs + t_val[:,None] * dirs        # (P,3)

    # Default colour = hit triangle colour
    colours   = CO[tri_idx].copy()                  # (P,3)
    m_tri_idx = tri_idx.copy()
    m_pos     = positions.copy()

    # Mirror triangles (4 or 5): reflect x-component of direction
    mirror_mask = any_hit & ((tri_idx == 4) | (tri_idx == 5))
    if mirror_mask.any():
        m_origs = positions[mirror_mask]
        m_dirs  = dirs[mirror_mask].copy()
        m_dirs[:, 0] *= -1.0
        mv, mt = _batch_PxN(m_origs, m_dirs, V0, E1, E2)
        mt_masked = np.where(mv, mt, INF)
        m_any = mv.any(axis=1)
        m_idx = mt_masked.argmin(axis=1).astype(int)
        m_t   = mt[np.arange(len(m_origs)), m_idx]

        dest = np.where(mirror_mask)[0]
        hit_dest = dest[m_any]
        m_tri_idx[hit_dest] = m_idx[m_any]
        m_pos[hit_dest]     = m_origs[m_any] + m_t[m_any,None] * m_dirs[m_any]
        colours[hit_dest]   = CO[m_idx[m_any]]

        # rays hitting mirror but no mirror target → keep wall colour already set

    return any_hit, tri_idx, t_val, positions, colours, m_tri_idx, m_pos


# ---------------------------------------------------------------------------
# LIGHTING — vectorized over P surface points

def _direct_light_batch(pos, tri_idx, m_pos, m_tri, V0, E1, E2, CO, NR, rng):
    """
    pos,m_pos: (P,3); tri_idx,m_tri: (P,) int
    Returns light (P,3), mirror_shadow (P,3)
    """
    def _compute(pts, tidx):
        P   = len(pts)
        SL  = LIGHT_POS - pts                        # (P,3) surface→light vector
        r   = np.linalg.norm(SL, axis=1)             # (P,)
        nrm = NR[tidx]                               # (P,3)
        dot = (SL * nrm).sum(axis=1)                 # (P,)
        adiv = 4.0 * math.pi * r**2                  # (P,)
        result = np.where(dot > 0.0,
                          dot / adiv,
                          0.0)[:,None] * LIGHT_COLOUR  # (P,3)

        # Primary shadow test
        any_h, occ_tri, _, occ_pos, _, _, _ = _scene_hit_batch(
            pts, SL, V0, E1, E2, CO, True
        )
        occ_dist = np.linalg.norm(occ_pos - pts, axis=1)
        in_shadow = (any_h &
                     (r > occ_dist) &
                     (dot > 0.0) &
                     (tidx != occ_tri))

        if not in_shadow.any():
            return result

        # Soft shadow — fully vectorized: S × SHADOW_N rays in one batch
        idx_sh   = np.where(in_shadow)[0]
        S        = len(idx_sh)
        pts_sh   = pts[idx_sh]                    # (S,3)
        tidx_sh  = tidx[idx_sh]                   # (S,)
        SL_sh    = SL[idx_sh]                     # (S,3)
        surf_col = CO[tidx_sh]                    # (S,3)

        # (S, SHADOW_N, 3) jittered directions
        offs     = rng.uniform(-SHADOW_R, SHADOW_R, size=(S, SHADOW_N, 3))
        dirs_all = SL_sh[:, None, :] + offs        # (S, SHADOW_N, 3)

        # Flatten to (S*SHADOW_N, 3) and test against all triangles at once
        origs_flat = np.repeat(pts_sh, SHADOW_N, axis=0)   # (S*SHADOW_N, 3)
        dirs_flat  = dirs_all.reshape(-1, 3)                # (S*SHADOW_N, 3)
        sv, _      = _batch_PxN(origs_flat, dirs_flat, V0, E1, E2, min_t=0.0)
        blocked    = sv.any(axis=1).reshape(S, SHADOW_N)    # (S, SHADOW_N)

        # For each shadow point: average colour of unblocked samples
        unblocked_frac = (~blocked).sum(axis=1) / SHADOW_N  # (S,)
        result[idx_sh] = surf_col * unblocked_frac[:, None]
        return result

    la = _compute(pos,   tri_idx)
    ms = _compute(m_pos, m_tri)
    return la, ms


# ---------------------------------------------------------------------------
# QUADRANT RENDERER

def _render_quadrant(args):
    area, V0, E1, E2, NR, CO = args
    W, H = SCREEN_WIDTH, SCREEN_HEIGHT
    rng  = np.random.default_rng(seed=(area+1)*12345)

    cy = math.cos(YAW); sy = math.sin(YAW)
    R  = np.array([[cy,0,sy],[0,1,0],[-sy,0,cy]])

    x0, y0 = [(0,0),(W//2,0),(0,H//2),(W//2,H//2)][area]
    qw, qh  = W//2, H//2
    quad    = np.zeros((qw,qh,3), dtype=np.float32)

    xs = np.arange(qw, dtype=np.float64) + x0   # pixel x coords for this quadrant

    # Thin-lens camera model:
    #   Lens plane : z = -2.0 (same as original screen plane)
    #   Focal plane: z = FOCAL = -0.5  →  focus distance = 1.5 (world units)
    #   Aperture   : disk of radius APERTURE centred on each pixel's lens-plane position
    #
    # For a point exactly on the focal plane, every aperture sample converges to the
    # same focal-plane target → perfectly sharp.  Points away from focal plane diverge
    # → natural circle-of-confusion blur.
    #
    # AA is handled by jittering the focal-plane target within the pixel footprint
    # (equivalent to jittering sub-pixel in pinhole model, but no extra rays needed).
    lens_z = -2.0

    for iy in range(qh):
        py = iy + y0

        acc_row = np.zeros((qw, 3), dtype=np.float64)

        # 4×4 stratified sampling — each stratum (si,sj) produces:
        #   • one AA jitter per pixel (moves focal-plane target within pixel)
        #   • one aperture-disk sample per pixel (DoF blur)
        for si in range(AA_SPP):
            for sj in range(AA_SPP):
                # ── AA: jitter focal-plane target within pixel footprint ──────────
                jx     = (sj + rng.random(size=qw)) / AA_SPP - 0.5  # (qw,) per-pixel
                jy_val = (si + rng.random())         / AA_SPP - 0.5  # scalar

                # World-space focal-plane target (C++ formula: uses CAMERA_Z for scale)
                ftx = (-0.5 + 0.5/W + (xs + jx)   / W) * (FOCAL - CAMERA_Z) / F_LEN  # (qw,)
                fty = (-0.5 + 0.5/H + (py + jy_val)/ H) * (FOCAL - CAMERA_Z) / F_LEN  # scalar

                # ── DoF: stratified concentric-disk aperture sample ───────────────
                u1 = (sj + rng.random(size=qw)) / AA_SPP  # (qw,) ∈ [0,1)
                u2 = (si + rng.random(size=qw)) / AA_SPP  # (qw,)
                a  = 2.0 * u1 - 1.0
                b  = 2.0 * u2 - 1.0
                # Shirley-Chiu concentric disk mapping (no clumping at centre)
                use_a = np.abs(a) >= np.abs(b)
                r_d   = np.where(use_a, a, b)
                phi   = np.where(
                    use_a,
                    (math.pi / 4.0) * (b / np.where(use_a & (a != 0), a, 1.0)),
                    (math.pi / 2.0) - (math.pi / 4.0) * (a / np.where(~use_a & (b != 0), b, 1.0))
                )
                disk_x = APERTURE * r_d * np.cos(phi)   # (qw,)
                disk_y = APERTURE * r_d * np.sin(phi)   # (qw,)

                # Ray origin: pixel-centre on lens plane + aperture disk offset
                lens_cx = -0.5 + 0.5/W + xs / W   # (qw,) pixel centre screen-x
                lens_cy = -0.5 + 0.5/H + py / H   # scalar
                orig_x  = lens_cx + disk_x         # (qw,)
                orig_y  = lens_cy + disk_y         # (qw,)  — scalar+array → array
                origs   = np.column_stack([orig_x, orig_y, np.full(qw, lens_z)])

                # Ray direction: aperture point → focal-plane target
                raw_d = np.column_stack([
                    ftx - orig_x,
                    fty - orig_y,
                    np.full(qw, FOCAL - lens_z)
                ])
                dirs = (R @ raw_d.T).T   # (qw,3)

                hit, tri, _, pos, colour, m_tri, m_pos = _scene_hit_batch(
                    origs, dirs, V0, E1, E2, CO, False
                )
                if not hit.any():
                    continue

                h_idx  = np.where(hit)[0]
                la, ms = _direct_light_batch(
                    pos[h_idx], tri[h_idx], m_pos[h_idx], m_tri[h_idx],
                    V0, E1, E2, CO, NR, rng
                )
                combined = 0.5 * (INDIRECT + (la + ms) / 2.0)
                acc_row[h_idx] += combined * colour[h_idx]

        quad[:, iy] = np.clip(acc_row / (AA_SPP*AA_SPP), 0.0, 1.0)

    return area, x0, y0, quad


# ---------------------------------------------------------------------------
# ASSEMBLE + SAVE

def draw(V0, E1, E2, NR, CO):
    tasks = [(i, V0, E1, E2, NR, CO) for i in range(4)]
    with mp.Pool(processes=4) as pool:
        results = pool.map(_render_quadrant, tasks)
    img = np.zeros((SCREEN_WIDTH, SCREEN_HEIGHT, 3), dtype=np.float32)
    for area, x0, y0, quad in results:
        img[x0:x0+SCREEN_WIDTH//2, y0:y0+SCREEN_HEIGHT//2] = quad
    return img


def save_bmp(img, path="screenshot.bmp"):
    arr = np.clip(img.transpose(1,0,2)*255.0, 0, 255).astype(np.uint8)
    Image.fromarray(arr).save(path)
    print(f"Saved {path}")


def main():
    V0, E1, E2, NR, CO = load_test_model()
    t0 = time.time()
    img = draw(V0, E1, E2, NR, CO)
    print(f"Render time: {(time.time()-t0)*1000:.1f} ms.")
    save_bmp(img)


if __name__ == '__main__':
    mp.freeze_support()
    main()
