// Geometry for the 3D game cases (fed to QtQuick3D.Helpers' ProceduralMesh): a box with slightly
// rounded corners and edges, built face by face so each face takes its own print (cover, spine,
// back, the console's plastic). Each face reaches to the middle of its rounded edges, where the
// next face takes over. On the large faces (front, back) its uv runs 0 → 1 across the flat part
// as seen from outside (v up): the whole print shows on the flat face, nothing of it bends away on
// the rounded edges, which carry the print's edge colour on. On the thin spines the print spans
// the face across its depth, rounded edges included (a flat strip alone would be too narrow), and
// the flat part only from top to bottom.
// Scene coordinates: x right, y up, z toward the viewer; the box is centred on the origin.
.pragma library

// Outward normal, right and up of each face as seen from outside.
const FACES = {
    front:  { n: [0, 0, 1],  r: [1, 0, 0],  u: [0, 1, 0] },
    back:   { n: [0, 0, -1], r: [-1, 0, 0], u: [0, 1, 0] },
    left:   { n: [-1, 0, 0], r: [0, 0, 1],  u: [0, 1, 0] },
    right:  { n: [1, 0, 0],  r: [0, 0, -1], u: [0, 1, 0] },
    top:    { n: [0, 1, 0],  r: [1, 0, 0],  u: [0, 0, -1] },
    bottom: { n: [0, -1, 0], r: [1, 0, 0],  u: [0, 0, 1] }
}

// Positions along one side, from -h to h: one long span in the middle, n steps across each
// rounded band of width r at the ends.
function steps(h, r, n) {
    const a = []
    for (let k = 0; k <= n; k++) a.push(-h + r * k / n)
    for (let k = n; k >= 0; k--) a.push(h - r * k / n)
    return a
}

function dot3(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }

// One face of a w × h × d box whose edges and corners are rounded with radius r.
function face(name, w, h, d, r, n) {
    n = n || 4
    const half = [w / 2, h / 2, d / 2]
    r = Math.max(0.01, Math.min(r, half[0] * 0.9, half[1] * 0.9, half[2] * 0.9))
    const f = FACES[name]
    const hr = Math.abs(dot3(f.r, half)), hu = Math.abs(dot3(f.u, half)), hn = Math.abs(dot3(f.n, half))
    const su = steps(hr, r, n), sv = steps(hu, r, n)
    const inner = [half[0] - r, half[1] - r, half[2] - r]
    const P = [], N = [], U = [], I = []
    for (let j = 0; j < sv.length; j++) {
        for (let i = 0; i < su.length; i++) {
            const p = [0, 1, 2].map(k => f.n[k] * hn + f.r[k] * su[i] + f.u[k] * sv[j])
            const c = [0, 1, 2].map(k => Math.max(-inner[k], Math.min(inner[k], p[k])))
            const dv = [p[0] - c[0], p[1] - c[1], p[2] - c[2]]
            const l = Math.sqrt(dot3(dv, dv)) || 1
            const nn = [dv[0] / l, dv[1] / l, dv[2] / l]
            P.push(Qt.vector3d(c[0] + nn[0] * r, c[1] + nn[1] * r, c[2] + nn[2] * r))
            N.push(Qt.vector3d(nn[0], nn[1], nn[2]))
            const flat = (s, hh) => Math.max(0, Math.min(1, (s + hh - r) / (2 * (hh - r))))
            const spine = name === "left" || name === "right"
            U.push(Qt.vector2d(spine ? (su[i] + hr) / (2 * hr) : flat(su[i], hr), flat(sv[j], hu)))
        }
    }
    const cols = su.length
    for (let j = 0; j < sv.length - 1; j++) {
        for (let i = 0; i < cols - 1; i++) {
            const a = j * cols + i, b = a + 1, c = a + cols + 1, e = a + cols
            I.push(a, b, c, a, c, e)
        }
    }
    return { positions: P, normals: N, uv0s: U, indexes: I }
}

// The whole box in one mesh (the ink outline drawn behind it).
function hull(w, h, d, r, n) {
    const out = { positions: [], normals: [], uv0s: [], indexes: [] }
    for (const k in FACES) {
        const m = face(k, w, h, d, r, n || 3)
        const base = out.positions.length
        out.positions = out.positions.concat(m.positions)
        out.normals = out.normals.concat(m.normals)
        out.uv0s = out.uv0s.concat(m.uv0s)
        out.indexes = out.indexes.concat(m.indexes.map(i => i + base))
    }
    return out
}
