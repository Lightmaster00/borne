// Geometry for the 3D game cases (fed to QtQuick3D.Helpers' ProceduralMesh). Everything is built
// in millimetre-like scene units around the case's centre: x right, y up, z toward the viewer.
//  slab()  — a block with rounded corners seen from the front and rounded edges around the front
//            and back faces: plastic shells, the clear jewel case, a cardboard box;
//  wrap()  — a sheet folded around the spine: back, spine, front in one piece, as a printed insert
//            or the clear sleeve over it lies on a keep case. Its u coordinate runs back → spine →
//            front, so one texture holding the three scans side by side follows the fold.
.pragma library

function v3(x, y, z) { return Qt.vector3d(x, y, z) }
function v2(x, y) { return Qt.vector2d(x, y) }

// Points around a rounded rectangle (half sizes hw, hh, corner radius r), counter-clockwise seen
// from the front, each with the outward direction of its corner arc.
function outline(hw, hh, r, seg) {
    const out = []
    const corners = [[hw - r, hh - r, 0], [-hw + r, hh - r, 90], [-hw + r, -hh + r, 180], [hw - r, -hh + r, 270]]
    for (const c of corners) {
        for (let i = 0; i <= seg; i++) {
            const a = (c[2] + 90 * i / seg) * Math.PI / 180
            out.push({ cx: c[0], cy: c[1], dx: Math.cos(a), dy: Math.sin(a) })
        }
    }
    return out
}

// Rounded block: w × h × (z1 - z0), corner radius r (front view), edge radius b (front and back
// edges). r is kept ≥ b so the edges stay smooth all round.
function slab(w, h, z0, z1, r, b, opts) {
    opts = opts || {}
    const seg = opts.seg || 6, bseg = opts.bseg || 4
    b = Math.max(0.01, Math.min(b, (z1 - z0) / 2 - 0.001, w / 2, h / 2))
    r = Math.max(r, b + 0.01)
    const ring = outline(w / 2, h / 2, r, seg)
    const P = [], N = [], U = [], I = []
    // Profile from the back face round to the front face: inset from the outline, z, normal.
    const prof = []
    for (let k = 0; k <= bseg; k++) {
        const t = k / bseg * Math.PI / 2
        prof.push({ inset: b * (1 - Math.sin(t)), z: z0 + b - b * Math.cos(t), s: Math.sin(t), c: -Math.cos(t) })
    }
    for (let k = 0; k <= bseg; k++) {
        const t = Math.PI / 2 + k / bseg * Math.PI / 2
        prof.push({ inset: b * (1 - Math.sin(t)), z: z1 - b - b * Math.cos(t), s: Math.sin(t), c: -Math.cos(t) })
    }
    const n = ring.length
    for (let p = 0; p < prof.length; p++) {
        const q = prof[p]
        for (let i = 0; i < n; i++) {
            const o = ring[i], rr = r - q.inset
            const x = o.cx + o.dx * rr, y = o.cy + o.dy * rr
            P.push(v3(x, y, q.z))
            N.push(v3(o.dx * q.s, o.dy * q.s, q.c))
            U.push(v2(i / n, p / (prof.length - 1)))
        }
    }
    for (let p = 0; p < prof.length - 1; p++) {
        for (let i = 0; i < n; i++) {
            const a = p * n + i, bb = p * n + (i + 1) % n, c = a + n, d = bb + n
            I.push(a, bb, d, a, d, c)
        }
    }
    // Caps: a fan from the centre of each face.
    function cap(z, nz, p) {
        const base = P.length
        P.push(v3(0, 0, z)); N.push(v3(0, 0, nz)); U.push(v2(0.5, 0.5))
        for (let i = 0; i < n; i++) {
            const src = P[p * n + i]
            P.push(v3(src.x, src.y, z)); N.push(v3(0, 0, nz))
            U.push(v2(src.x / w + 0.5, src.y / h + 0.5))
        }
        for (let i = 0; i < n; i++) {
            const a = base + 1 + i, bb = base + 1 + (i + 1) % n
            if (nz > 0) I.push(base, a, bb); else I.push(base, bb, a)
        }
    }
    cap(z1, 1, prof.length - 1)
    cap(z0, -1, 0)
    return { positions: P, normals: N, uv0s: U, indexes: I }
}

// A sheet folded round the spine: it lies on the back (z = -dz), turns round the left edge
// (x = -hw) on arcs of radius rs and comes back over the front (z = +dz), from x = xr on the back
// to x = xr on the front, between y = -hh and +hh. Returns the mesh and the share of u taken by
// the back, the spine and the front, for the texture laid out to match.
function wrap(hw, dz, xr, hh, rs, opts) {
    opts = opts || {}
    const aseg = opts.aseg || 6
    rs = Math.max(0.05, Math.min(rs, dz, hw))
    const path = []   // {x, z, nx, nz}
    const push = (x, z, nx, nz) => path.push({ x: x, z: z, nx: nx, nz: nz })
    push(xr, -dz, 0, -1)
    // back-left corner: centre (-hw + rs, -dz + rs), angle 270° → 180°
    for (let i = 0; i <= aseg; i++) {
        const a = (270 - 90 * i / aseg) * Math.PI / 180
        push(-hw + rs + rs * Math.cos(a), -dz + rs + rs * Math.sin(a), Math.cos(a), Math.sin(a))
    }
    // front-left corner: centre (-hw + rs, dz - rs), angle 180° → 90°
    for (let i = 0; i <= aseg; i++) {
        const a = (180 - 90 * i / aseg) * Math.PI / 180
        push(-hw + rs + rs * Math.cos(a), dz - rs + rs * Math.sin(a), Math.cos(a), Math.sin(a))
    }
    push(xr, dz, 0, 1)
    const len = [0]
    for (let i = 1; i < path.length; i++)
        len.push(len[i - 1] + Math.hypot(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z))
    const total = len[len.length - 1]
    const P = [], N = [], U = [], I = []
    for (let i = 0; i < path.length; i++) {
        const q = path[i], u = len[i] / total
        P.push(v3(q.x, -hh, q.z)); N.push(v3(q.nx, 0, q.nz)); U.push(v2(u, 0))
        P.push(v3(q.x, hh, q.z)); N.push(v3(q.nx, 0, q.nz)); U.push(v2(u, 1))
    }
    for (let i = 0; i < path.length - 1; i++) {
        const a = 2 * i, b = a + 1, c = a + 2, d = a + 3
        I.push(a, d, b, a, c, d)
    }
    const back = (xr - (-hw + rs)) / total
    return { positions: P, normals: N, uv0s: U, indexes: I, back: back, front: back, spine: 1 - 2 * back }
}

// Apply a mesh to a ProceduralMesh.
function apply(pm, m) {
    pm.positions = m.positions
    pm.normals = m.normals
    pm.uv0s = m.uv0s
    pm.indexes = m.indexes
}
