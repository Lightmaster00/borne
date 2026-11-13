// Borne's case finish, second skin over the game cases: added on top of the shaded prints.
// The case is seen through clear plastic, like glass: it reflects a photo studio (a large softbox
// above on the left, tall windows on the sides, a thin strip on the right, a faint sheen across), weak when seen face-on and
// strong at grazing angles (Fresnel), so the print stays clean and the reflections slide over it
// as the case turns. (No rim on the edges: seen side-on, it drew a light line along the spines.)
//
// Uniform (CustomMaterial property): glint (reflection strength).

// A soft-edged band: 1 between a and b, fading over f outside.
float band(float x, float a, float b, float f)
{
    return smoothstep(a - f, a, x) * (1.0 - smoothstep(b, b + f, x));
}

void MAIN()
{
    BASE_COLOR = vec4(0.0, 0.0, 0.0, 1.0);
    METALNESS = 0.0;
    ROUGHNESS = 0.3;
    SPECULAR_AMOUNT = 0.0;
    vec3 n = normalize(VAR_WORLD_NORMAL);
    vec3 v = normalize(VIEW_VECTOR);
    float facing = clamp(dot(n, v), 0.0, 1.0);
    // The direction the eye sees reflected, as longitude and latitude (camera behind +z).
    vec3 r = reflect(-v, n);
    float lon = atan(r.x, r.z);
    float lat = asin(clamp(r.y, -1.0, 1.0));
    // The studio: a large softbox above on the left, a thin strip on the right, a diagonal sheen
    // that crosses the face when it looks at the eye, and a dim ceiling.
    float softbox = band(lon, -0.95, -0.35, 0.18) * band(lat, 0.22, 0.75, 0.15);
    float strip = band(lon, 0.52, 0.60, 0.05) * band(lat, -0.35, 0.65, 0.2) * 0.7;
    // Tall windows on both sides: they sweep over the face as the case turns.
    float windows = (band(lon, -1.55, -1.05, 0.2) + band(lon, 1.15, 1.45, 0.12) * 0.6) * band(lat, -0.25, 0.7, 0.25) * 0.8;
    float sheen = band(lon * 0.8 - lat, 0.10, 0.17, 0.08) * 0.6;
    float ceiling = smoothstep(0.1, 0.9, lat) * 0.12;
    float studio = softbox + strip + windows + sheen + ceiling;
    float fresnel = 0.04 + 0.96 * pow(1.0 - facing, 5.0);
    vec3 reflection = vec3(0.92, 0.95, 1.0) * studio * glint * mix(0.3, 1.0, fresnel);
    EMISSIVE_COLOR = reflection;
}

void DIRECTIONAL_LIGHT()
{
}

void AMBIENT_LIGHT()
{
}

void SPECULAR_LIGHT()
{
    // The key light's own glint: broad and soft, never a hard white spot.
    vec3 h = normalize(VIEW_VECTOR + TO_LIGHT_DIR);
    float s = pow(max(0.0, dot(h, normalize(NORMAL))), 24.0);
    SPECULAR += LIGHT_COLOR * glint * 0.18 * s * SHADOW_CONTRIB;
}

void IBL_PROBE()
{
}
