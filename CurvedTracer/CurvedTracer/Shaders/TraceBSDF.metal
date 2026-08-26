#ifndef CURVED_TRACER_TRACE_BSDF_METAL
#define CURVED_TRACER_TRACE_BSDF_METAL

// Material model resolution, evaluation, and sampling.

#include "TraceMath.metal"

static int resolveBSDFModel(MaterialGPU material) {
    // Keep the currently implemented endpoints explicit so a rough or
    // transmissive material cannot silently fall back to diffuse rendering.
    if (material.transmission >= 1.0f - EPS && material.metallic <= EPS)
        return material.roughness <= EPS
        ? BSDF_MODEL_DELTA_DIELECTRIC : BSDF_MODEL_GGX_DIELECTRIC;
    if (material.transmission > EPS)
        return BSDF_MODEL_UNSUPPORTED;
    if (material.metallic >= 1.0f - EPS)
        return material.roughness <= EPS
        ? BSDF_MODEL_DELTA_REFLECTION : BSDF_MODEL_GGX_CONDUCTOR;
    if (material.metallic <= EPS)
        return material.roughness <= EPS
        ? BSDF_MODEL_LAMBERTIAN : BSDF_MODEL_GGX_OPAQUE_DIELECTRIC;
    return BSDF_MODEL_UNSUPPORTED;
}

static bool isSupportedBSDFModel(int model) {
    return model == BSDF_MODEL_LAMBERTIAN ||
    model == BSDF_MODEL_DELTA_REFLECTION ||
    model == BSDF_MODEL_DELTA_DIELECTRIC ||
    model == BSDF_MODEL_GGX_CONDUCTOR ||
    model == BSDF_MODEL_GGX_DIELECTRIC ||
    model == BSDF_MODEL_GGX_OPAQUE_DIELECTRIC;
}

static float ggxAlpha(MaterialGPU material) {
    float perceptualRoughness = clamp(material.roughness, 0.0f, 1.0f);
    return max(perceptualRoughness * perceptualRoughness, 1e-3f);
}

static float ggxDistribution(float cosineHalf, float alpha) {
    if (cosineHalf <= 0.0f)
        return 0.0f;
    float alphaSquared = alpha * alpha;
    float denominator =
    cosineHalf * cosineHalf * (alphaSquared - 1.0f) + 1.0f;
    const float inversePi = 0.31830988618f;
    return alphaSquared * inversePi /
    max(denominator * denominator, 1e-12f);
}

static float ggxSmithG1(float cosineDirection, float alpha) {
    if (cosineDirection <= 0.0f)
        return 0.0f;
    float cosineSquared = cosineDirection * cosineDirection;
    float root = sqrt(max(
        alpha * alpha + (1.0f - alpha * alpha) * cosineSquared, 0.0f));
    return 2.0f * cosineDirection /
    max(cosineDirection + root, EPS);
}

static float3 conductorSchlickFresnel(float cosineHalf, float3 f0) {
    float oneMinusCosine = 1.0f - clamp(cosineHalf, 0.0f, 1.0f);
    float square = oneMinusCosine * oneMinusCosine;
    float fifthPower = square * square * oneMinusCosine;
    f0 = clamp(f0, 0.0f, 1.0f);
    return f0 + (1.0f - f0) * fifthPower;
}

static float dielectricFresnel(
    float cosineIncident,
    float incidentIOR,
    float transmittedIOR,
    thread float &cosineTransmitted);

static float opaqueDielectricSpecularProbability(
    MaterialGPU material,
    float incomingCosine
) {
    float ignoredTransmittedCosine = 0.0f;
    float fresnel = dielectricFresnel(
        incomingCosine, 1.0f, material.ior,
        ignoredTransmittedCosine);
    return clamp(fresnel, 0.05f, 0.95f);
}

static BSDFEvaluation evaluateBSDF(
    MaterialGPU material,
    float4 normal,
    bool frontFace,
    float4 incomingDirection,
    float4 outgoingDirection
) {
    BSDFEvaluation evaluation{};
    int model = resolveBSDFModel(material);
    if (model == BSDF_MODEL_DELTA_REFLECTION ||
        model == BSDF_MODEL_DELTA_DIELECTRIC) {
        evaluation.valid = 1;
        return evaluation;
    }
    if (model == BSDF_MODEL_GGX_CONDUCTOR) {
        float incomingCosine = clamp(
            mdot(normal, incomingDirection), 0.0f, 1.0f);
        float outgoingCosine = clamp(
            mdot(normal, outgoingDirection), 0.0f, 1.0f);
        if (incomingCosine <= 0.0f || outgoingCosine <= 0.0f)
            return evaluation;
        float4 halfDirection = tangentNormalize(
            incomingDirection + outgoingDirection);
        float halfCosine = clamp(
            mdot(normal, halfDirection), 0.0f, 1.0f);
        float incomingHalfCosine = clamp(
            mdot(incomingDirection, halfDirection), 0.0f, 1.0f);
        if (halfCosine <= 0.0f || incomingHalfCosine <= 0.0f)
            return evaluation;
        float alpha = ggxAlpha(material);
        float distribution = ggxDistribution(halfCosine, alpha);
        float incomingMasking = ggxSmithG1(incomingCosine, alpha);
        float outgoingMasking = ggxSmithG1(outgoingCosine, alpha);
        float3 fresnel = conductorSchlickFresnel(
            incomingHalfCosine, material.baseColor.rgb);
        evaluation.value = fresnel * distribution * incomingMasking *
        outgoingMasking /
        max(4.0f * incomingCosine * outgoingCosine, EPS);
        // The visible-normal density is D(h) G1(wi) (wi·h)/(n·wi).
        // Reflection's 1/(4 wi·h) Jacobian cancels its final factor.
        evaluation.pdf = distribution * incomingMasking /
        max(4.0f * incomingCosine, EPS);
        evaluation.valid = all(isfinite(evaluation.value)) &&
        isfinite(evaluation.pdf) && evaluation.pdf > 0.0f;
        return evaluation;
    }
    if (model == BSDF_MODEL_GGX_OPAQUE_DIELECTRIC) {
        float incomingCosine = mdot(normal, incomingDirection);
        float outgoingCosine = mdot(normal, outgoingDirection);
        if (incomingCosine <= EPS || outgoingCosine <= EPS)
            return evaluation;
        float4 halfDirection = tangentNormalize(
            incomingDirection + outgoingDirection);
        float halfCosine = mdot(normal, halfDirection);
        if (halfCosine < 0.0f) {
            halfDirection = -halfDirection;
            halfCosine = -halfCosine;
        }
        float incomingHalfCosine =
        mdot(incomingDirection, halfDirection);
        if (halfCosine <= 0.0f || incomingHalfCosine <= 0.0f)
            return evaluation;

        float ignoredTransmittedCosine = 0.0f;
        float microfacetFresnel = dielectricFresnel(
            incomingHalfCosine, 1.0f, material.ior,
            ignoredTransmittedCosine);
        float incomingFresnel = dielectricFresnel(
            incomingCosine, 1.0f, material.ior,
            ignoredTransmittedCosine);
        float outgoingFresnel = dielectricFresnel(
            outgoingCosine, 1.0f, material.ior,
            ignoredTransmittedCosine);
        float alpha = ggxAlpha(material);
        float distribution = ggxDistribution(halfCosine, alpha);
        float incomingMasking = ggxSmithG1(incomingCosine, alpha);
        float outgoingMasking = ggxSmithG1(outgoingCosine, alpha);
        float3 specular = float3(
            microfacetFresnel * distribution * incomingMasking *
            outgoingMasking /
            max(4.0f * incomingCosine * outgoingCosine, EPS));
        const float inversePi = 0.31830988618f;
        float3 diffuse = clamp(material.baseColor.rgb, 0.0f, 1.0f) *
        (1.0f - incomingFresnel) * (1.0f - outgoingFresnel) *
        inversePi;
        evaluation.value = specular + diffuse;

        float specularProbability = opaqueDielectricSpecularProbability(
            material, incomingCosine);
        float specularPDF = distribution * incomingMasking /
        max(4.0f * incomingCosine, EPS);
        float diffusePDF = outgoingCosine * inversePi;
        evaluation.pdf = specularProbability * specularPDF +
        (1.0f - specularProbability) * diffusePDF;
        evaluation.valid = all(isfinite(evaluation.value)) &&
        isfinite(evaluation.pdf) && evaluation.pdf > 0.0f;
        return evaluation;
    }
    if (model == BSDF_MODEL_GGX_DIELECTRIC) {
        float incomingCosine = mdot(normal, incomingDirection);
        float outgoingCosine = mdot(normal, outgoingDirection);
        if (incomingCosine <= EPS || abs(outgoingCosine) <= EPS)
            return evaluation;
        float incidentIOR = frontFace ? 1.0f : material.ior;
        float transmittedIOR = frontFace ? material.ior : 1.0f;
        float alpha = ggxAlpha(material);
        float incomingMasking = ggxSmithG1(incomingCosine, alpha);
        if (outgoingCosine > 0.0f) {
            float4 halfDirection = tangentNormalize(
                incomingDirection + outgoingDirection);
            float halfCosine = mdot(normal, halfDirection);
            if (halfCosine < 0.0f) {
                halfDirection = -halfDirection;
                halfCosine = -halfCosine;
            }
            float incomingHalfCosine =
            mdot(incomingDirection, halfDirection);
            if (halfCosine <= 0.0f || incomingHalfCosine <= 0.0f)
                return evaluation;
            float ignoredTransmittedCosine = 0.0f;
            float fresnel = dielectricFresnel(
                incomingHalfCosine, incidentIOR, transmittedIOR,
                ignoredTransmittedCosine);
            float distribution = ggxDistribution(halfCosine, alpha);
            float masking = incomingMasking *
            ggxSmithG1(outgoingCosine, alpha);
            evaluation.value = float3(
                fresnel * distribution * masking /
                max(4.0f * incomingCosine * outgoingCosine, EPS));
            evaluation.pdf = fresnel * distribution * incomingMasking /
            max(4.0f * incomingCosine, EPS);
        } else {
            float4 halfDirection = tangentNormalize(-(
                incidentIOR * incomingDirection +
                transmittedIOR * outgoingDirection));
            float halfCosine = mdot(normal, halfDirection);
            if (halfCosine < 0.0f) {
                halfDirection = -halfDirection;
                halfCosine = -halfCosine;
            }
            float incomingHalfCosine =
            mdot(incomingDirection, halfDirection);
            float outgoingHalfCosine =
            mdot(outgoingDirection, halfDirection);
            if (halfCosine <= 0.0f || incomingHalfCosine <= 0.0f ||
                outgoingHalfCosine >= 0.0f)
                return evaluation;
            float ignoredTransmittedCosine = 0.0f;
            float fresnel = dielectricFresnel(
                incomingHalfCosine, incidentIOR, transmittedIOR,
                ignoredTransmittedCosine);
            float oneMinusFresnel = 1.0f - fresnel;
            if (oneMinusFresnel <= 0.0f)
                return evaluation;
            float denominator = incidentIOR * incomingHalfCosine +
            transmittedIOR * outgoingHalfCosine;
            float denominatorSquared = denominator * denominator;
            if (denominatorSquared <= 1e-12f)
                return evaluation;
            float distribution = ggxDistribution(halfCosine, alpha);
            float outgoingMasking = ggxSmithG1(-outgoingCosine, alpha);
            float masking = incomingMasking * outgoingMasking;
            float directionalProduct = abs(
                incomingHalfCosine * outgoingHalfCosine);
            float transmissionScale =
            incidentIOR * incidentIOR / denominatorSquared;
            evaluation.value = clamp(material.baseColor.rgb, 0.0f, 1.0f) *
            oneMinusFresnel * distribution * masking * directionalProduct *
            transmissionScale /
            max(incomingCosine * -outgoingCosine, EPS);
            float visibleNormalPDF = distribution * incomingMasking *
            incomingHalfCosine / max(incomingCosine, EPS);
            // Walter's refractive half-vector mapping contributes eta_t²
            // |wo·h| / (eta_i wi·h + eta_t wo·h)² to the directional PDF.
            float refractionJacobian =
            transmittedIOR * transmittedIOR * abs(outgoingHalfCosine) /
            denominatorSquared;
            evaluation.pdf = visibleNormalPDF * oneMinusFresnel *
            refractionJacobian;
        }
        evaluation.valid = all(isfinite(evaluation.value)) &&
        isfinite(evaluation.pdf) && evaluation.pdf > 0.0f;
        return evaluation;
    }
    if (model != BSDF_MODEL_LAMBERTIAN)
        return evaluation;
    evaluation.valid = 1;
    float outgoingCosine = clamp(
        mdot(normal, outgoingDirection), 0.0f, 1.0f);
    if (outgoingCosine <= 0.0f)
        return evaluation;
    const float inversePi = 0.31830988618f;
    evaluation.value =
    clamp(material.baseColor.rgb, 0.0f, 1.0f) * inversePi;
    evaluation.pdf = outgoingCosine * inversePi;
    return evaluation;
}

static float dielectricFresnel(
    float cosineIncident,
    float incidentIOR,
    float transmittedIOR,
    thread float &cosineTransmitted
) {
    cosineIncident = clamp(cosineIncident, 0.0f, 1.0f);
    if (abs(incidentIOR - transmittedIOR) <= EPS) {
        cosineTransmitted = cosineIncident;
        return 0.0f;
    }
    float eta = incidentIOR / transmittedIOR;
    float sineTransmittedSquared = eta * eta * max(
        1.0f - cosineIncident * cosineIncident, 0.0f);
    if (sineTransmittedSquared >= 1.0f) {
        cosineTransmitted = 0.0f;
        return 1.0f;
    }
    cosineTransmitted = sqrt(max(1.0f - sineTransmittedSquared, 0.0f));
    float parallelNumerator =
    transmittedIOR * cosineIncident - incidentIOR * cosineTransmitted;
    float parallelDenominator =
    transmittedIOR * cosineIncident + incidentIOR * cosineTransmitted;
    float perpendicularNumerator =
    incidentIOR * cosineIncident - transmittedIOR * cosineTransmitted;
    float perpendicularDenominator =
    incidentIOR * cosineIncident + transmittedIOR * cosineTransmitted;
    float parallel = parallelNumerator / max(parallelDenominator, EPS);
    float perpendicular =
    perpendicularNumerator / max(perpendicularDenominator, EPS);
    return clamp(
        0.5f * (parallel * parallel + perpendicular * perpendicular),
        0.0f, 1.0f);
}

static bool sampleGGXVisibleNormal(
    float4 point,
    float4 normal,
    float4 viewDirection,
    float alpha,
    float2 randomSample,
    thread float4 &microfacetNormal
) {
    float4 first, second;
    if (!bsdfTangentFrame(point, normal, first, second))
        return false;
    float3 localView = float3(
        mdot(viewDirection, first), mdot(viewDirection, second),
        mdot(viewDirection, normal));
    if (localView.z <= 0.0f)
        return false;

    float3 stretchedView = normalize(float3(
        alpha * localView.x, alpha * localView.y, localView.z));
    float lensSquared = dot(stretchedView.xy, stretchedView.xy);
    float3 firstDiskAxis = lensSquared > EPS * EPS
    ? float3(-stretchedView.y, stretchedView.x, 0.0f) *
      rsqrt(lensSquared)
    : float3(1, 0, 0);
    float3 secondDiskAxis = cross(stretchedView, firstDiskAxis);

    float radius = sqrt(clamp(randomSample.x, 0.0f, 1.0f));
    float azimuth = TWO_PI * clamp(randomSample.y, 0.0f, 1.0f);
    float diskX = radius * cos(azimuth);
    float diskY = radius * sin(azimuth);
    float blend = 0.5f * (1.0f + stretchedView.z);
    diskY = (1.0f - blend) * sqrt(max(1.0f - diskX * diskX, 0.0f)) +
    blend * diskY;
    float diskZ = sqrt(max(
        1.0f - diskX * diskX - diskY * diskY, 0.0f));
    float3 stretchedNormal =
    diskX * firstDiskAxis + diskY * secondDiskAxis +
    diskZ * stretchedView;
    float3 localNormal = normalize(float3(
        alpha * stretchedNormal.x, alpha * stretchedNormal.y,
        max(stretchedNormal.z, 1e-6f)));
    microfacetNormal = tangentNormalize(
        localNormal.x * first + localNormal.y * second +
        localNormal.z * normal);
    return all(isfinite(microfacetNormal)) &&
    mdot(microfacetNormal, microfacetNormal) > 0.5f &&
    mdot(viewDirection, microfacetNormal) > 0.0f;
}

static BSDFSample sampleBSDF(
    MaterialGPU material,
    float4 point,
    float4 incidentDirection,
    float4 normal,
    bool frontFace,
    float3 randomSample
) {
    BSDFSample sample{};
    int model = resolveBSDFModel(material);
    if (model == BSDF_MODEL_DELTA_REFLECTION) {
        sample.direction = tangentNormalize(
            incidentDirection -
            2.0f * mdot(incidentDirection, normal) * normal);
        sample.weight = clamp(material.baseColor.rgb, 0.0f, 1.0f);
        sample.pdf = 1.0f;
        sample.eventType = BSDF_EVENT_SPECULAR_REFLECTION;
        sample.delta = 1;
        sample.valid = all(isfinite(sample.direction)) &&
        mdot(sample.direction, sample.direction) > 0.5f;
        return sample;
    }
    if (model == BSDF_MODEL_GGX_CONDUCTOR) {
        float4 viewDirection = -incidentDirection;
        float4 microfacetNormal;
        if (!sampleGGXVisibleNormal(
                point, normal, viewDirection, ggxAlpha(material),
                randomSample.xy, microfacetNormal))
            return sample;
        float viewHalfCosine = mdot(viewDirection, microfacetNormal);
        sample.direction = tangentNormalize(
            incidentDirection + 2.0f * viewHalfCosine * microfacetNormal);
        sample.eventType = BSDF_EVENT_GLOSSY_REFLECTION;
        sample.delta = 0;
        float outgoingCosine = mdot(normal, sample.direction);
        if (outgoingCosine <= 0.0f) {
            // VNDF sampling can still select a facet whose reflected ray lies
            // below the macrosurface. This is a valid zero-contribution sample,
            // not malformed geometry.
            sample.valid = all(isfinite(sample.direction)) &&
            mdot(sample.direction, sample.direction) > 0.5f;
            return sample;
        }
        BSDFEvaluation evaluation = evaluateBSDF(
            material, normal, frontFace, viewDirection, sample.direction);
        if (!evaluation.valid || evaluation.pdf <= 0.0f)
            return BSDFSample{};
        // With a visible-normal PDF and separable Smith G, f cos(theta) / pdf
        // reduces exactly to F * G1(wo). Use that bounded form directly to
        // avoid a numerically fragile division near sharp highlights.
        sample.weight = conductorSchlickFresnel(
            viewHalfCosine, material.baseColor.rgb) *
        ggxSmithG1(outgoingCosine, ggxAlpha(material));
        sample.pdf = evaluation.pdf;
        sample.valid = all(isfinite(sample.direction)) &&
        all(isfinite(sample.weight)) &&
        mdot(sample.direction, sample.direction) > 0.5f;
        return sample;
    }
    if (model == BSDF_MODEL_GGX_OPAQUE_DIELECTRIC) {
        float4 viewDirection = -incidentDirection;
        float incomingCosine = mdot(normal, viewDirection);
        if (incomingCosine <= 0.0f)
            return sample;
        if (incomingCosine <= EPS) {
            // The evaluator intentionally excludes this numerically unstable
            // grazing band. Terminate it without classifying the finite ray
            // as malformed.
            sample.direction = normal;
            sample.valid = all(isfinite(sample.direction)) &&
            mdot(sample.direction, sample.direction) > 0.5f;
            return sample;
        }
        float specularProbability = opaqueDielectricSpecularProbability(
            material, incomingCosine);
        if (randomSample.z < specularProbability) {
            float4 microfacetNormal;
            if (!sampleGGXVisibleNormal(
                    point, normal, viewDirection, ggxAlpha(material),
                    randomSample.xy, microfacetNormal))
                return sample;
            float viewHalfCosine = mdot(viewDirection, microfacetNormal);
            sample.direction = tangentNormalize(
                incidentDirection + 2.0f * viewHalfCosine *
                microfacetNormal);
            sample.eventType = BSDF_EVENT_GLOSSY_REFLECTION;
        } else {
            float4 first, second;
            if (!bsdfTangentFrame(point, normal, first, second))
                return sample;
            float radial = sqrt(clamp(randomSample.x, 0.0f, 1.0f));
            float azimuth = TWO_PI * clamp(randomSample.y, 0.0f, 1.0f);
            sample.direction = tangentNormalize(
                radial * cos(azimuth) * first +
                radial * sin(azimuth) * second +
                sqrt(max(1.0f - radial * radial, 0.0f)) * normal);
            sample.eventType = BSDF_EVENT_DIFFUSE;
        }
        sample.delta = 0;
        float outgoingCosine = mdot(normal, sample.direction);
        if (outgoingCosine <= EPS) {
            sample.valid = all(isfinite(sample.direction)) &&
            mdot(sample.direction, sample.direction) > 0.5f;
            return sample;
        }
        BSDFEvaluation evaluation = evaluateBSDF(
            material, normal, frontFace, viewDirection, sample.direction);
        if (!evaluation.valid || evaluation.pdf <= 0.0f)
            return BSDFSample{};
        sample.weight = evaluation.value * outgoingCosine / evaluation.pdf;
        sample.pdf = evaluation.pdf;
        sample.valid = all(isfinite(sample.direction)) &&
        all(isfinite(sample.weight)) &&
        mdot(sample.direction, sample.direction) > 0.5f;
        return sample;
    }
    if (model == BSDF_MODEL_GGX_DIELECTRIC) {
        if (abs(material.ior - 1.0f) <= EPS) {
            sample.direction = tangentNormalize(incidentDirection);
            sample.weight = clamp(material.baseColor.rgb, 0.0f, 1.0f);
            sample.pdf = 1.0f;
            sample.eventType = BSDF_EVENT_GLOSSY_TRANSMISSION;
            sample.delta = 1;
            sample.valid = all(isfinite(sample.direction)) &&
            mdot(sample.direction, sample.direction) > 0.5f;
            return sample;
        }
        float4 viewDirection = -incidentDirection;
        float incomingCosine = mdot(normal, viewDirection);
        if (incomingCosine <= 0.0f)
            return sample;
        if (incomingCosine <= EPS) {
            // Match evaluateBSDF's grazing cutoff with a valid path
            // termination instead of reporting an invalid BSDF sample.
            sample.direction = normal;
            sample.valid = all(isfinite(sample.direction)) &&
            mdot(sample.direction, sample.direction) > 0.5f;
            return sample;
        }
        float alpha = ggxAlpha(material);
        float4 microfacetNormal;
        if (!sampleGGXVisibleNormal(
                point, normal, viewDirection, alpha, randomSample.xy,
                microfacetNormal))
            return sample;
        float viewHalfCosine = mdot(viewDirection, microfacetNormal);
        float incidentIOR = frontFace ? 1.0f : material.ior;
        float transmittedIOR = frontFace ? material.ior : 1.0f;
        float transmittedHalfCosine = 0.0f;
        float fresnel = dielectricFresnel(
            viewHalfCosine, incidentIOR, transmittedIOR,
            transmittedHalfCosine);
        bool reflect = randomSample.z < fresnel;
        if (reflect) {
            sample.direction = tangentNormalize(
                incidentDirection + 2.0f * viewHalfCosine *
                microfacetNormal);
            sample.eventType = BSDF_EVENT_GLOSSY_REFLECTION;
        } else {
            float eta = incidentIOR / transmittedIOR;
            sample.direction = tangentNormalize(
                eta * incidentDirection +
                (eta * viewHalfCosine - transmittedHalfCosine) *
                microfacetNormal);
            sample.eventType = BSDF_EVENT_GLOSSY_TRANSMISSION;
        }
        sample.delta = 0;
        float outgoingCosine = mdot(normal, sample.direction);
        bool validHemisphere = reflect
        ? outgoingCosine > EPS : outgoingCosine < -EPS;
        if (!validHemisphere) {
            sample.valid = all(isfinite(sample.direction)) &&
            mdot(sample.direction, sample.direction) > 0.5f;
            return sample;
        }
        BSDFEvaluation evaluation = evaluateBSDF(
            material, normal, frontFace, viewDirection, sample.direction);
        if (!evaluation.valid || evaluation.pdf <= 0.0f)
            return BSDFSample{};
        float outgoingMasking = ggxSmithG1(abs(outgoingCosine), alpha);
        sample.weight = reflect
        ? float3(outgoingMasking)
        : clamp(material.baseColor.rgb, 0.0f, 1.0f) * outgoingMasking *
          (incidentIOR * incidentIOR /
           (transmittedIOR * transmittedIOR));
        sample.pdf = evaluation.pdf;
        sample.valid = all(isfinite(sample.direction)) &&
        all(isfinite(sample.weight)) &&
        mdot(sample.direction, sample.direction) > 0.5f;
        return sample;
    }
    if (model == BSDF_MODEL_DELTA_DIELECTRIC) {
        float incidentIOR = frontFace ? 1.0f : material.ior;
        float transmittedIOR = frontFace ? material.ior : 1.0f;
        float cosineIncident = clamp(
            -mdot(incidentDirection, normal), 0.0f, 1.0f);
        float cosineTransmitted = 0.0f;
        float fresnel = dielectricFresnel(
            cosineIncident, incidentIOR, transmittedIOR,
            cosineTransmitted);
        bool reflect = randomSample.z < fresnel;
        if (reflect) {
            sample.direction = tangentNormalize(
                incidentDirection + 2.0f * cosineIncident * normal);
            sample.weight = float3(1);
            sample.pdf = fresnel;
            sample.eventType = BSDF_EVENT_SPECULAR_REFLECTION;
        } else {
            float eta = incidentIOR / transmittedIOR;
            sample.direction = tangentNormalize(
                eta * incidentDirection +
                (eta * cosineIncident - cosineTransmitted) * normal);
            // Radiance transport across a refractive interface carries the
            // squared relative-IOR Jacobian. Entry and exit factors cancel for
            // an un-nested closed object; baseColor supplies boundary tint.
            sample.weight =
            clamp(material.baseColor.rgb, 0.0f, 1.0f) * eta * eta;
            sample.pdf = 1.0f - fresnel;
            sample.eventType = BSDF_EVENT_SPECULAR_TRANSMISSION;
        }
        sample.delta = 1;
        sample.valid = sample.pdf > 0.0f &&
        all(isfinite(sample.direction)) && all(isfinite(sample.weight)) &&
        mdot(sample.direction, sample.direction) > 0.5f;
        return sample;
    }
    if (model != BSDF_MODEL_LAMBERTIAN)
        return sample;

    float4 first, second;
    if (!bsdfTangentFrame(point, normal, first, second))
        return sample;
    float radial = sqrt(clamp(randomSample.x, 0.0f, 1.0f));
    float azimuth = TWO_PI * clamp(randomSample.y, 0.0f, 1.0f);
    sample.direction = tangentNormalize(
        radial * cos(azimuth) * first + radial * sin(azimuth) * second +
        sqrt(max(1.0f - radial * radial, 0.0f)) * normal);
    BSDFEvaluation evaluation = evaluateBSDF(
        material, normal, frontFace, -incidentDirection, sample.direction);
    float cosine = clamp(mdot(normal, sample.direction), 0.0f, 1.0f);
    if (!evaluation.valid || evaluation.pdf <= 0.0f || cosine <= 0.0f)
        return BSDFSample{};
    sample.weight = evaluation.value * cosine / evaluation.pdf;
    sample.pdf = evaluation.pdf;
    sample.eventType = BSDF_EVENT_DIFFUSE;
    sample.delta = 0;
    sample.valid = all(isfinite(sample.direction)) &&
    all(isfinite(sample.weight));
    return sample;
}


#endif
