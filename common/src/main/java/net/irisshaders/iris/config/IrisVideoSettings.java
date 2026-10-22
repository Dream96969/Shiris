package net.irisshaders.iris.config;

import net.irisshaders.iris.Iris;
import net.irisshaders.iris.pathways.colorspace.ColorSpace;

/**
 * Runtime video settings shared by the pipeline, shadow renderer and uniforms.
 * Holds state only; the video settings UI that used to live next to it was removed in Phase 1.
 */
public class IrisVideoSettings {
	public static int shadowDistance = 32;
	public static ColorSpace colorSpace = ColorSpace.SRGB;

	public static int getOverriddenShadowDistance(int base) {
		return Iris.getPipelineManager().getPipeline()
			.map(pipeline -> pipeline.getForcedShadowRenderDistanceChunksForDisplay().orElse(base))
			.orElse(base);
	}
}
