// The face of GlassSurface: tint, dark border, inner bevel shadow and edge glint,
// drawn analytically over the blurred backdrop.
//
// Ported from liquid_glass_renderer 1.0.0-dev.2 (lib/assets/shaders/fake_glass_surface.frag
// and fake_glass_shape.glsl), Copyright 2025 Tim Lehmann for whynotmake.it, licensed
// under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
// Changed: both files merged into one; logic unchanged.
//
// sdRoundedBox and sdEllipse follow Inigo Quilez's 2D distance functions
// (https://iquilezles.org/articles/distfunctions2d/), MIT License, Copyright © 2015 Inigo Quilez.
// sdRoundedSuperellipse is adapted from Flutter's Impeller (impeller/entity/shaders/uber_sdf.frag,
// Flutter 3.47.1), Copyright 2013 The Flutter Authors, BSD-style license.

#version 460 core
precision mediump float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uShapeType;
uniform float uCornerRadius;
uniform vec4 uTint;
uniform float uHighlight;
uniform float uHighlightWidth;
uniform float uThickness;
uniform float uHighlightWrap;
uniform float uOppositeHighlight;
uniform float uContourStrength;
uniform float uContourWidth;
uniform float uContourTransmittance;
uniform float uContourOffset;
uniform float uContourDirectionality;
uniform float uBevelStrength;
uniform float uBevelDepth;
uniform float uBevelOffset;
uniform float uBevelDirectionality;
uniform float uBevelSizeResponse;
uniform vec2 uLightDirection;
// Logical size of one physical pixel.
uniform float uPixelSize;
// 1 when drawing only the border ring outside the shape clip.
uniform float uExteriorOnly;
// Luminance of the neutral glint target.
uniform float uGlintLuminance;
// Premultiplied emission of the face the backdrop filter produced.
uniform vec3 uFaceEmission;
// Rounded superellipse parameters (see roundedSuperellipseParameters in glass_surface.dart).
uniform vec4 uRseDegreeAndSpans;
uniform vec4 uRseCircleCenters;
uniform vec4 uRseSemiAxisAndRadii;
uniform float uGlintFaceGain;
uniform float uGlintVibrancy;
// 1 when drawing only the additive highlight pass.
uniform float uHighlightsOnly;

const vec3 LUMA_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);
const float kAdditiveHighlightScale = 0.75;

layout(location = 0) out vec4 fragColor;

float sdRoundedBox(vec2 p, vec2 halfSize, float radius) {
    radius = clamp(radius, 0.0, min(halfSize.x, halfSize.y));
    vec2 q = abs(p) - halfSize + vec2(radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float sdEllipse(vec2 p, vec2 radius) {
    radius = max(radius, vec2(0.001));
    float k0 = length(p / radius);
    float k1 = length(p / (radius * radius));
    return k0 * (k0 - 1.0) / max(k1, 0.001);
}

float sdSuperellipseArc(vec2 p, float n) {
    p = abs(p) + vec2(1e-6);
    float s = pow(p.x, n) + pow(p.y, n);
    float f = pow(s, 1.0 / n) - 1.0;
    vec2 gradient = vec2(pow(p.x, n - 1.0), pow(p.y, n - 1.0)) *
        pow(s, 1.0 / n - 1.0);
    return f / max(length(gradient), 1e-3);
}

float sdRoundedSuperellipse(
    vec2 p,
    vec2 halfSize,
    float radius,
    vec4 degreeAndSpans,
    vec4 circleCenters,
    vec4 semiAxisAndRadii
) {
    if (radius <= 1e-4) {
        return max(abs(p).x - halfSize.x, abs(p).y - halfSize.y);
    }
    vec2 local = abs(p);
    float c = semiAxisAndRadii.x - semiAxisAndRadii.y;
    vec2 octant;
    float degree;
    float span;
    float axis;
    float circleRadius;
    vec2 circleCenter;
    if (local.y + c > local.x) {
        octant = local + vec2(0.0, c);
        degree = degreeAndSpans.x;
        axis = semiAxisAndRadii.x;
        span = degreeAndSpans.z;
        circleCenter = circleCenters.xy;
        circleRadius = semiAxisAndRadii.z;
    } else {
        octant = local.yx - vec2(0.0, c);
        degree = degreeAndSpans.y;
        axis = semiAxisAndRadii.y;
        span = degreeAndSpans.w;
        circleCenter = circleCenters.zw;
        circleRadius = semiAxisAndRadii.w;
    }
    vec2 relative = octant - circleCenter;
    float deltaTheta = atan(relative.y, relative.x) - 0.78539816;
    deltaTheta = mod(deltaTheta + 3.14159265, 6.28318531) - 3.14159265;
    if (abs(deltaTheta) < abs(span)) {
        return length(relative) - circleRadius;
    }
    if (degree < 2.0) {
        return max(abs(octant).x - axis, abs(octant).y - axis);
    }
    return sdSuperellipseArc(octant / max(axis, 1e-4), degree) * axis;
}

// type: 0 oval, 1 rounded rectangle, 2 rounded superellipse.
float sdGlassShape(
    float type,
    vec2 p,
    vec2 halfSize,
    float radius,
    vec4 degreeAndSpans,
    vec4 circleCenters,
    vec4 semiAxisAndRadii
) {
    if (type < 0.5) {
        return sdEllipse(p, halfSize);
    }
    float box = sdRoundedBox(p, halfSize, radius);
    if (type < 1.5 || box < -6.0) {
        return box;
    }
    float superellipse = sdRoundedSuperellipse(
        p,
        halfSize,
        min(radius, min(halfSize.x, halfSize.y)),
        degreeAndSpans,
        circleCenters,
        semiAxisAndRadii
    );
    return mix(superellipse, box, smoothstep(4.0, 6.0, -box));
}

float shapeDistance(vec2 p) {
  return sdGlassShape(
    uShapeType,
    p,
    uSize * 0.5,
    uCornerRadius,
    uRseDegreeAndSpans,
    uRseCircleCenters,
    uRseSemiAxisAndRadii
  );
}

vec2 shapeNormal(vec2 p) {
  vec2 halfSize = uSize * 0.5;
  if (uShapeType < 0.5) {
    vec2 radius = max(halfSize, vec2(0.001));
    return normalize(p / (radius * radius) + vec2(0.00001));
  }
  float radius = clamp(uCornerRadius, 0.0, min(halfSize.x, halfSize.y));
  vec2 q = abs(p) - halfSize + vec2(radius);
  vec2 corner = max(q, 0.0);
  if (dot(corner, corner) > 0.0001) {
    return normalize(corner) * sign(p);
  }
  return q.x > q.y ? vec2(sign(p.x), 0.0) : vec2(0.0, sign(p.y));
}

// Integral of the border ramp from the silhouette to outward distance t, in physical pixels.
float contourIntegral(float t, float offset, float width) {
  float u = clamp(t - offset, 0.0, width);
  return u - u * u / (2.0 * width);
}

void main() {
  vec2 position = FlutterFragCoord().xy - uSize * 0.5;
  float distance = shapeDistance(position);
  float inward = max(-distance, 0.0);

  vec2 normal = shapeNormal(position);
  vec2 lightDirection = normalize(uLightDirection + vec2(0.00001));
  float facing = dot(normal, -lightDirection);

  float tangency = abs(dot(normal, vec2(-lightDirection.y, lightDirection.x)));

  float glintWidth = max(
    uHighlightWidth > 0.0 ? uHighlightWidth : uContourWidth,
    0.001
  );
  float glintProfile =
      clamp(1.0 - inward / glintWidth, 0.0, 1.0) +
      0.21 * clamp(1.0 - inward / (glintWidth * 4.0), 0.0, 1.0);
  float wrapExponent = exp2(2.0 - 4.0 * clamp(uHighlightWrap, 0.0, 1.0));
  float lobe = pow(max(1.0 - tangency, 0.0), wrapExponent);
  float returnWeight = facing >= 0.0
      ? 1.0
      : clamp(uOppositeHighlight, 0.0, 1.0);
  float glint = clamp(
    max(uHighlight, 0.0) * 0.252 * lobe * returnWeight * glintProfile,
    0.0,
    1.0
  );

  float tintAlpha = uTint.a;
  vec3 faceProxy = uTint.rgb * tintAlpha + uFaceEmission;
  vec3 glintTarget = vec3(uGlintLuminance) +
      uGlintFaceGain * faceProxy +
      uGlintVibrancy * (faceProxy - vec3(dot(faceProxy, LUMA_WEIGHTS)));
  float materialCoverage = uExteriorOnly > 0.5
      ? 0.0
      : clamp(0.5 - distance / uPixelSize, 0.0, 1.0);
  if (uHighlightsOnly > 0.5) {
    fragColor = vec4(
      max(glintTarget, vec3(0.0)) * glint * materialCoverage *
          kAdditiveHighlightScale,
      0.0
    );
    return;
  }
  float outwardPixels = distance / uPixelSize;
  float contourOffsetPixels = uContourOffset / uPixelSize;
  float contourWidthPixels = uContourWidth / uPixelSize;
  vec2 contourBand = vec2(0.0);
  if (uContourWidth > 0.0) {
    float lower = outwardPixels - 0.5;
    float upper = outwardPixels + 0.5;
    contourBand = vec2(
      contourIntegral(max(upper, 0.0), contourOffsetPixels, contourWidthPixels) -
          contourIntegral(max(lower, 0.0), contourOffsetPixels, contourWidthPixels),
      contourIntegral(min(upper, 0.0), contourOffsetPixels, contourWidthPixels) -
          contourIntegral(min(lower, 0.0), contourOffsetPixels, contourWidthPixels)
    );
  }
  float contourStrength = clamp(uContourStrength, 0.0, 1.0) *
      mix(1.0, tangency, clamp(uContourDirectionality, 0.0, 1.0));
  float silhouetteCoverage = clamp(0.5 - outwardPixels, 0.0, 1.0);
  float contourAbsorption = clamp(
    contourBand.y / max(silhouetteCoverage, 0.001) * contourStrength,
    0.0,
    1.0
  );
  float backdropContourAbsorption = contourAbsorption *
      (1.0 - clamp(uContourTransmittance, 0.0, 1.0));
  float bevelShadow = 0.0;

  float bevelDepth = max(uBevelDepth, 0.001);
  float sizeProgress = smoothstep(
    bevelDepth * 3.5,
    bevelDepth * 5.0,
    min(uSize.x, uSize.y) * 0.5
  );
  float bevelEnergy = mix(
    1.0,
    1.875,
    sizeProgress * clamp(uBevelSizeResponse, 0.0, 1.0)
  );
  float bevelShift = max(uBevelOffset, 0.0) * facing;
  float bevelPenumbra = 2.0 * bevelShift;
  float bevelLeading = bevelPenumbra > 0.001
      ? smoothstep(0.0, bevelPenumbra, inward)
      : 1.0;
  float bevelFalloff = 1.0 - smoothstep(0.0, bevelDepth, inward - bevelShift);
  float wrappedFacing = smoothstep(0.0, 1.0, facing * 0.5 + 0.5);
  float directionalShadow = mix(
    1.0,
    wrappedFacing,
    clamp(uBevelDirectionality, 0.0, 1.0)
  );
  bevelShadow = clamp(
    bevelLeading * bevelFalloff * directionalShadow *
        uBevelStrength * bevelEnergy,
    0.0,
    1.0
  );
  float backdropAbsorption = 1.0 -
      (1.0 - backdropContourAbsorption) * (1.0 - bevelShadow);
  float materialAlpha = 1.0 - (1.0 - tintAlpha) *
      (1.0 - backdropAbsorption);
  float exteriorContourAlpha = clamp(contourBand.x * contourStrength, 0.0, 1.0);
  vec3 litPremultiplied =
      uTint.rgb * tintAlpha * (1.0 - contourAbsorption) +
      uFaceEmission * bevelShadow * (1.0 - tintAlpha) *
          (1.0 - backdropContourAbsorption);
  float litAlpha = materialAlpha;
  if (litAlpha < 0.999) {
    litPremultiplied = min(litPremultiplied, vec3(1.0));
    litAlpha = max(
      litAlpha,
      max(max(litPremultiplied.r, litPremultiplied.g), litPremultiplied.b)
    );
  }
  float alpha = litAlpha * materialCoverage + exteriorContourAlpha;
  fragColor = vec4(
    max(litPremultiplied * materialCoverage, vec3(0.0)),
    clamp(alpha, 0.0, 1.0)
  );
}
