// Borne's cel shading for the game cases (Qt Quick 3D custom material, shaded).
// Drawn as a skin just over the case and multiplied onto its flat, unlit prints: flat light bands
// instead of a smooth falloff with a hard terminator, the dark side in the console's colour rather
// than grey, and a fine grain (paper fibres or moulded plastic).
//
// Uniforms (CustomMaterial properties): grainTex, shadeTint, midTint, grainAmount, grainScale.

float grain;

void MAIN()
{
    vec3 g = texture(grainTex, UV0 * grainScale).rgb - 0.5;
    grain = (g.r + g.g) * grainAmount;
    BASE_COLOR = vec4(1.0);
    METALNESS = 0.0;
    ROUGHNESS = 1.0;
    SPECULAR_AMOUNT = 0.0;
}

void DIRECTIONAL_LIGHT()
{
    float nl = dot(normalize(NORMAL), TO_LIGHT_DIR);
    // Lit and half-tone bands; below them only the ambient (the console-coloured dark side).
    float lit = smoothstep(0.40, 0.44, nl);
    float halfTone = smoothstep(0.0, 0.04, nl) - lit;
    float shadow = mix(0.55, 1.0, smoothstep(0.45, 0.55, SHADOW_CONTRIB));
    DIFFUSE += LIGHT_COLOR * (lit * vec3(1.0) + halfTone * midTint.rgb) * shadow;
}

void AMBIENT_LIGHT()
{
    DIFFUSE += shadeTint.rgb + vec3(grain);
}

void SPECULAR_LIGHT()
{
}

void IBL_PROBE()
{
}
