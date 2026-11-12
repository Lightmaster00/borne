// Borne's cel shading, second skin over the game cases: added on top of the shaded prints.
// A crisp highlight spot where the key light glints (varnish, clear plastic) and a rim of the
// console's colour along the edges turning away from the eye, both with hard edges.
//
// Uniforms (CustomMaterial properties): rimColor, rimStrength, glint.

void MAIN()
{
    BASE_COLOR = vec4(0.0, 0.0, 0.0, 1.0);
    METALNESS = 0.0;
    ROUGHNESS = 0.3;
    SPECULAR_AMOUNT = 1.0;
    float facing = clamp(dot(normalize(VAR_WORLD_NORMAL), normalize(VIEW_VECTOR)), 0.0, 1.0);
    EMISSIVE_COLOR = rimColor.rgb * rimStrength * (1.0 - smoothstep(0.22, 0.27, facing));
}

void DIRECTIONAL_LIGHT()
{
}

void AMBIENT_LIGHT()
{
}

void SPECULAR_LIGHT()
{
    vec3 h = normalize(VIEW_VECTOR + TO_LIGHT_DIR);
    float s = pow(max(0.0, dot(h, normalize(NORMAL))), 60.0);
    SPECULAR += LIGHT_COLOR * glint * smoothstep(0.50, 0.55, s) * SHADOW_CONTRIB;
}

void IBL_PROBE()
{
}
