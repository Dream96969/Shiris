package net.irisshaders.iris.lights;

import com.mojang.blaze3d.opengl.GlStateManager;
import it.unimi.dsi.fastutil.longs.Long2ObjectMap;
import it.unimi.dsi.fastutil.longs.Long2ObjectOpenHashMap;
import it.unimi.dsi.fastutil.objects.Reference2ObjectOpenHashMap;
import net.irisshaders.iris.Iris;
import net.irisshaders.iris.gl.GLDebug;
import net.irisshaders.iris.gl.IrisRenderSystem;
import net.irisshaders.iris.gl.sampler.SamplerLimits;
import net.irisshaders.iris.uniforms.CapturedRenderingState;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import org.joml.Matrix4fc;
import org.joml.Vector3d;
import org.lwjgl.opengl.GL43C;
import org.lwjgl.opengl.GL46C;
import org.lwjgl.system.MemoryUtil;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Iterator;
import java.util.function.Predicate;

/**
 * HalilShaders light list.
 *
 * Iris tells shaders nothing about where individual light sources are, so this class finds them
 * on the CPU and hands them to the pack through a shader storage buffer (SSBO) that is bound at
 * {@link #BINDING} for the whole frame. The pack reads it in lib/lights.glsl.
 *
 * The reach of the list follows the player's render distance: every loaded chunk column within the
 * render distance is searched (and vertically 6 sections, 96 blocks, up and down from the camera).
 *
 * How it works:
 *  1. Scanning works on chunk sections (16 x 16 x 16 blocks). A section whose block palette holds
 *     no light-emitting state is skipped without looking at a single block. Sections that do hold
 *     emitters are read block by block, and the lights found are remembered per section.
 *  2. Every frame a small, time-limited amount of scanning is done: a few chunk columns right around
 *     the camera (so a placed torch shows up within about half a second) and then as many columns
 *     as fit in a fraction of a millisecond, walking outward over the whole render distance and
 *     starting over when done.
 *  3. When the remembered lights actually changed (or the camera moved far enough that the grid needs
 *     re-centering), the lights are sorted into a world-aligned grid of CELL_SIZE-block cells. A
 *     light is entered in every cell its reach touches, and each cell keeps at most CELL_LIGHTS
 *     lights (the ones that matter most to that cell). A surface reads only its own cell, so it gets
 *     the lights close to IT, wherever the camera is.
 *  4. Separately, the MAX_LIGHTS lights most influential to the CAMERA (close and strong) form the
 *     halo list. Halos are drawn along view rays, not on surfaces, so they use this short list.
 *     Lights that cannot show a halo are kept out of it, so they cost nothing per pixel and do not
 *     take a slot from a light that can be seen:
 *      - lights outside the camera's view (with a margin for the glow and for fast turning);
 *      - lights hidden behind solid blocks. A light counts as hidden only if rays from the camera to
 *        its middle AND to eight points around it (the size of its glow) are all stopped by an opaque
 *        full block well before they reach it. A light behind a one block pole is therefore kept,
 *        because the rays to the points beside it pass the pole. Tests are limited per frame and
 *        remembered for a few frames; a light that was not tested yet counts as visible, and lights
 *        fade in and out instead of switching.
 *     The surface lighting grid is NOT culled this way: it is evaluated only for the pixels that
 *     are on screen anyway, and a light behind a wall still lights the room on its own side.
 *
 * Only the first HALO_END bytes (header and halo list) are uploaded every frame. Light positions in
 * the candidate list are relative to the GRID corner, not to the camera, so they stay valid while
 * the camera moves; the shader gets the camera-to-corner offset from the header. The candidate
 * list and the grid are uploaded only when they are rebuilt.
 *
 * Buffer layout (std430). Offsets in bytes:
 *   0        ivec4 header;           // x = number of lights in the halo list
 *   16       ivec4 gridDims;         // xyz = grid size in cells (x, y, z)
 *   32       vec4  gridOrigin;       // xyz = grid corner minus camera, world axes
 *   48       Light haloLights[32];   // the halo list, positions relative to the camera
 *   1072     Light candidates[32768];// every known light, positions relative to the grid corner
 *   1049648  int   grid[];           // gridDims.x * gridDims.y * gridDims.z cells of 16 ints:
 *                                    // [count, index0 .. index14]; cell = (x * dimsY + y) * dimsZ + z
 * where Light is { vec4 posRadius; vec4 colorIntensity; } (32 bytes):
 *   posRadius      = xyz: light center minus the reference point (world axes), w: reach in blocks
 *   colorIntensity = rgb: color, a: emission level / 15
 * The grid is (2 * renderChunks + 6) cells wide in x and z and 20 cells (320 blocks) tall. It is
 * only moved when the camera is more than 2 cells away from its center, which leaves at least
 * renderChunks * 16 blocks of coverage around the camera at all times.
 *
 * Known limits: all lights are point lights without occlusion (the Phase 8 work adds shadows), and
 * lights in chunks the client has not loaded are not seen. Render distance is capped at
 * MAX_RENDER_CHUNKS.
 */
public final class LightSourceBuffer {
	/** SSBO binding index. Packs in this project must not use this index for their own buffers. */
	public static final int BINDING = 7;
	/** Length of the halo list. Halos are rendered at half resolution, so 32 ranked lights are sufficient. */
	public static final int MAX_LIGHTS = 32;

	/** Cells are at least as wide as the largest reach (15), so a light touches at most 2 cells per axis. */
	private static final int CELL_SIZE = 16;
	/** Ints per cell: the count, then the light indices. */
	private static final int CELL_STRIDE_INTS = 16;
	private static final int CELL_LIGHTS = CELL_STRIDE_INTS - 1;

	private static final int MIN_RENDER_CHUNKS = 2;
	private static final int MAX_RENDER_CHUNKS = 32;
	/** Grid width in cells is 2 * renderChunks + this. */
	private static final int GRID_MARGIN_CELLS = 6;
	private static final int GRID_Y = 20;
	/** The grid is re-centered when the camera is more than this many cells from its center. */
	private static final int RECENTER_SLACK = 2;
	private static final int MAX_GRID_XZ = 2 * MAX_RENDER_CHUNKS + GRID_MARGIN_CELLS;
	private static final int MAX_GRID_CELLS = MAX_GRID_XZ * GRID_Y * MAX_GRID_XZ;

	/** Sections scanned above and below the camera's section. Must stay inside the grid (see above). */
	private static final int SCAN_SECTIONS_Y = 6;
	/** Known lights kept (closest to the camera first). */
	private static final int MAX_CANDIDATES = 32768;

	private static final int LIGHT_BYTES = 32;
	private static final int HEADER_BYTES = 48;
	private static final int HALO_OFFSET = HEADER_BYTES;
	private static final int HALO_END = HALO_OFFSET + MAX_LIGHTS * LIGHT_BYTES;
	private static final int CANDIDATE_OFFSET = HALO_END;
	private static final int GRID_OFFSET = CANDIDATE_OFFSET + MAX_CANDIDATES * LIGHT_BYTES;
	private static final int BUFFER_BYTES = GRID_OFFSET + MAX_GRID_CELLS * CELL_STRIDE_INTS * 4;

	/** Chunk columns within this many chunks of the camera (squared) are rescanned most often. */
	private static final int NEAR_RADIUS_SQ = 9;
	private static final int NEAR_COLUMNS_PER_FRAME = 2;
	/** Time the outward walk may spend per frame, and a hard cap on columns, so one frame never stalls. */
	private static final long FAR_BUDGET_NANOS = 500_000L;
	private static final int FAR_MAX_COLUMNS_PER_FRAME = 64;
	/** The lists are rebuilt at most this often (in frames) unless the grid has to move. */
	private static final int MIN_REBUILD_FRAMES = 10;

	/** The halo list is picked from the best-ranked lights in view, up to this many, after hidden ones are dropped. */
	private static final int RANK_CAP = 192;
	/** Lights tested for hiding per frame, and how many frames a result is kept. */
	private static final int OCCLUSION_TESTS_PER_FRAME = 12;
	private static final int OCCLUSION_TTL_FRAMES = 8;
	/** Lights nearer or farther than this (blocks) are never tested: they count as visible. */
	private static final double OCCLUSION_MIN_DIST = 4.0;
	private static final double OCCLUSION_MAX_DIST = 96.0;
	/**
	 * A solid block this close in front of a sample point does not hide it. The halo also shows on the
	 * wall around a torch, because the glow is drawn wherever the scene is not more than about a
	 * block in front of the light (HALO_FRONT_BIAS in settings.glsl, plus the 0.5 fade).
	 */
	private static final double OCCLUSION_SURFACE_TOLERANCE = 1.3;
	/** The view frustum is widened by this angle, so lights just outside it are ready when the camera turns. */
	private static final double VIEW_SLACK_RADIANS = 0.35;

	/**
	 * Level of detail for halos. A halo whose visible part is smaller than HALO_MIN_PIXELS on screen is
	 * only a flickering dot, so the light is left out; it fades in up to HALO_FULL_PIXELS. The size on
	 * screen follows the window height and the field of view. HALO_RADIUS_BLOCKS must match HALO_RADIUS
	 * in settings.glsl. HALO_VISIBLE_SIGMAS is how far out the glow is still visible, in units of its
	 * angular radius (the shader cuts it off at 3, and it is faint beyond about 2.4).
	 */
	private static final double HALO_RADIUS_BLOCKS = 0.60;
	private static final double HALO_VISIBLE_SIGMAS = 2.4;
	private static final double HALO_MIN_PIXELS = 1.5;
	private static final double HALO_FULL_PIXELS = 3.0;

	private static final Direction[] DIRECTIONS = Direction.values();
	private static final Light[] NO_LIGHTS = new Light[0];
	private static final Predicate<BlockState> EMITS_LIGHT = state -> state.getLightEmission() > 0;

	private final boolean enabled;
	private final Reference2ObjectOpenHashMap<Block, float[]> colorCache = new Reference2ObjectOpenHashMap<>();
	private final BlockPos.MutableBlockPos neighbor = new BlockPos.MutableBlockPos();
	private final Light[] picked = new Light[MAX_LIGHTS];
	private final double[] pickedScore = new double[MAX_LIGHTS];

	// Halo list culling: best-ranked lights in view, the camera axes in world space for this frame,
	// and the widened frustum shape.
	private final Light[] ranked = new Light[RANK_CAP];
	private final double[] rankedScore = new double[RANK_CAP];
	private final float[] rankedDetail = new float[RANK_CAP];
	private final float[] pickedDetail = new float[MAX_LIGHTS];
	/** Screen pixels per radian at the center of the view, from the window height and field of view. */
	private double pixelsPerRadian;
	private final BlockPos.MutableBlockPos rayPos = new BlockPos.MutableBlockPos();
	private double rightX, rightY, rightZ;
	private double upX, upY, upZ;
	private double backX, backY, backZ;
	private double tanX, tanY;
	private int frame;

	// Grid build scratch space (sized for the largest grid).
	private final int[] gridCount = new int[MAX_GRID_CELLS];
	private final int[] gridIndex = new int[MAX_GRID_CELLS * CELL_LIGHTS];
	private final float[] gridScore = new float[MAX_GRID_CELLS * CELL_LIGHTS];

	private ByteBuffer staging;
	private int bufferId;

	/** Lights found per chunk section, keyed by {@link #sectionKey}. Only sections that hold lights are stored. */
	private final Long2ObjectOpenHashMap<Light[]> sectionLights = new Long2ObjectOpenHashMap<>();
	private Light[] committed = NO_LIGHTS;
	private ClientLevel scannedLevel;
	private boolean lightsDirty = true;
	private int framesSinceRebuild;

	/** Chunk columns (dx, dz) around the camera, nearest first, for the current render distance. */
	private int[][] columnOrder = new int[0][];
	private int orderChunks = -1;
	private int nearCount = 1;
	private int nearCursor;
	private int farCursor;

	/** Cell coordinates of the grid's first cell, its width in cells (x and z), and whether it is valid. */
	private boolean gridValid;
	private int gridChunks;
	private int gridWidth;
	private int gridCellX;
	private int gridCellY;
	private int gridCellZ;

	/**
	 * One light-emitting block. Identity (equals and hashCode) is the block, its color and its level;
	 * the fields below the constructor are halo culling state and are not part of it. A light that is
	 * found unchanged by a rescan keeps its old object, so this state survives rescans.
	 */
	private static final class Light {
		private final int x;
		private final int y;
		private final int z;
		private final float r;
		private final float g;
		private final float b;
		private final int level;

		/** Frame of the last hiding test, whether it found the light hidden, and the smoothed 0..1 result. */
		private int testFrame = -1_000_000;
		private boolean hidden;
		private float visibility = 1.0F;

		Light(int x, int y, int z, float r, float g, float b, int level) {
			this.x = x;
			this.y = y;
			this.z = z;
			this.r = r;
			this.g = g;
			this.b = b;
			this.level = level;
		}

		int x() {
			return x;
		}

		int y() {
			return y;
		}

		int z() {
			return z;
		}

		float r() {
			return r;
		}

		float g() {
			return g;
		}

		float b() {
			return b;
		}

		int level() {
			return level;
		}

		@Override
		public boolean equals(Object other) {
			if (this == other) {
				return true;
			}

			if (!(other instanceof Light light)) {
				return false;
			}

			return x == light.x && y == light.y && z == light.z && level == light.level
				&& Float.compare(r, light.r) == 0 && Float.compare(g, light.g) == 0 && Float.compare(b, light.b) == 0;
		}

		@Override
		public int hashCode() {
			return ((x * 31 + y) * 31 + z) * 31 + level;
		}
	}

	public LightSourceBuffer() {
		this.enabled = IrisRenderSystem.supportsSSBO() && SamplerLimits.get().getMaxShaderStorageUnits() > BINDING;

		if (!enabled) {
			Iris.logger.warn("[HalilShaders] Shader storage buffers with binding " + BINDING + " are not available; the light list is disabled.");
			return;
		}

		this.bufferId = IrisRenderSystem.createBuffers();
		GlStateManager._glBindBuffer(GL43C.GL_SHADER_STORAGE_BUFFER, bufferId);
		IrisRenderSystem.bufferStorage(GL43C.GL_SHADER_STORAGE_BUFFER, BUFFER_BYTES, GL46C.GL_DYNAMIC_STORAGE_BIT);
		GLDebug.nameObject(GL43C.GL_BUFFER, bufferId, "HalilShaders light list");
		GlStateManager._glBindBuffer(GL43C.GL_SHADER_STORAGE_BUFFER, 0);

		this.staging = MemoryUtil.memAlloc(BUFFER_BYTES);
		// The grid part of the staging buffer is only rewritten when the grid changes, so it must
		// start out as all zero (every cell empty).
		MemoryUtil.memSet(staging, 0);

		// Start with a valid empty list (zero lights, zero-size grid) so a frame that renders before
		// the first update reads nothing.
		uploadDynamic(0, new Vector3d());
		bind();
	}

	public boolean isEnabled() {
		return enabled;
	}

	/**
	 * Call once per frame before any pass that reads the list.
	 *
	 * @param camera unshifted camera position (world coordinates).
	 */
	public void update(Vector3d camera) {
		if (!enabled) {
			return;
		}

		ClientLevel level = Minecraft.getInstance().level;
		int count = 0;

		if (level != null) {
			int chunks = renderChunks();
			advanceScan(level, camera, chunks);
			refreshLists(camera, chunks);
			count = selectHaloLights(level, camera);
		}

		uploadDynamic(count, camera);

		// Cheap, and guards against anything else having rebound this index since last frame.
		bind();
	}

	public void destroy() {
		if (!enabled) {
			return;
		}

		IrisRenderSystem.bindBufferBase(GL43C.GL_SHADER_STORAGE_BUFFER, BINDING, 0);
		// Same as ShaderStorageBuffer: do not use the GlStateManager version of the delete.
		IrisRenderSystem.deleteBuffers(bufferId);
		MemoryUtil.memFree(staging);
		staging = null;
	}

	private void bind() {
		IrisRenderSystem.bindBufferBase(GL43C.GL_SHADER_STORAGE_BUFFER, BINDING, bufferId);
	}

	/** The player's render distance in chunks, kept inside the range the buffer is sized for. */
	private static int renderChunks() {
		int distance = Minecraft.getInstance().options.renderDistance().get();
		return Math.max(MIN_RENDER_CHUNKS, Math.min(MAX_RENDER_CHUNKS, distance));
	}

	// ---- scanning ----

	private void advanceScan(ClientLevel level, Vector3d camera, int chunks) {
		if (level != scannedLevel) {
			// New world or dimension: whatever we knew is wrong.
			scannedLevel = level;
			sectionLights.clear();
			committed = NO_LIGHTS;
			orderChunks = -1;
			gridValid = false;
			lightsDirty = true;
		}

		if (chunks != orderChunks) {
			buildColumnOrder(chunks);
		}

		int cameraChunkX = Math.floorDiv((int) Math.floor(camera.x), 16);
		int cameraChunkZ = Math.floorDiv((int) Math.floor(camera.z), 16);
		int cameraSectionY = Math.floorDiv((int) Math.floor(camera.y), 16);

		// Right around the camera: always, so edits there show up quickly.
		for (int i = 0; i < NEAR_COLUMNS_PER_FRAME; i++) {
			int[] column = columnOrder[nearCursor % nearCount];
			nearCursor++;
			scanColumn(level, cameraChunkX + column[0], cameraChunkZ + column[1], cameraSectionY);
		}

		// Outward over the whole render distance, as far as the time budget allows.
		long start = System.nanoTime();
		int done = 0;

		do {
			int[] column = columnOrder[farCursor % columnOrder.length];
			farCursor++;
			scanColumn(level, cameraChunkX + column[0], cameraChunkZ + column[1], cameraSectionY);
			done++;
		} while (done < FAR_MAX_COLUMNS_PER_FRAME && System.nanoTime() - start < FAR_BUDGET_NANOS);

		// Do not let the cursors grow without bound.
		nearCursor %= nearCount;
		farCursor %= columnOrder.length;
	}

	/** Lists the chunk columns within the render distance, nearest first. */
	private void buildColumnOrder(int chunks) {
		ArrayList<int[]> columns = new ArrayList<>();

		for (int dx = -chunks; dx <= chunks; dx++) {
			for (int dz = -chunks; dz <= chunks; dz++) {
				columns.add(new int[]{dx, dz});
			}
		}

		columns.sort(Comparator.comparingInt(column -> column[0] * column[0] + column[1] * column[1]));
		columnOrder = columns.toArray(new int[0][]);

		int near = 0;

		for (int[] column : columnOrder) {
			if (column[0] * column[0] + column[1] * column[1] <= NEAR_RADIUS_SQ) {
				near++;
			}
		}

		nearCount = Math.max(1, near);
		orderChunks = chunks;
		nearCursor = 0;
		farCursor = 0;
	}

	private void scanColumn(ClientLevel level, int chunkX, int chunkZ, int cameraSectionY) {
		LevelChunk chunk = level.getChunkSource().getChunkNow(chunkX, chunkZ);

		int minSection = level.getMinSectionY();
		int lowSection = Math.max(cameraSectionY - SCAN_SECTIONS_Y, minSection);
		int highSection = Math.min(cameraSectionY + SCAN_SECTIONS_Y, minSection + level.getSectionsCount() - 1);

		for (int sectionY = lowSection; sectionY <= highSection; sectionY++) {
			long key = sectionKey(chunkX, sectionY, chunkZ);

			if (chunk == null) {
				// Chunk not (or no longer) loaded: forget its lights.
				if (sectionLights.remove(key) != null) {
					lightsDirty = true;
				}
				continue;
			}

			scanSection(level, chunk.getSection(sectionY - minSection), chunkX, sectionY, chunkZ, key);
		}
	}

	/** Reads one section and stores (or clears) its lights. Marks the lights dirty only if they changed. */
	private void scanSection(ClientLevel level, LevelChunkSection section, int chunkX, int sectionY, int chunkZ, long key) {
		Light[] found = NO_LIGHTS;

		// Cheap test on the section's palette: most sections have no emitter at all.
		if (section.maybeHas(EMITS_LIGHT)) {
			ArrayList<Light> list = null;
			int baseX = chunkX * 16;
			int baseY = sectionY * 16;
			int baseZ = chunkZ * 16;

			for (int y = 0; y < 16; y++) {
				for (int z = 0; z < 16; z++) {
					for (int x = 0; x < 16; x++) {
						BlockState state = section.getBlockState(x, y, z);
						int emission = state.getLightEmission();

						if (emission <= 0) {
							continue;
						}

						int worldX = baseX + x;
						int worldY = baseY + y;
						int worldZ = baseZ + z;

						if (isInsideLightMass(level, worldX, worldY, worldZ)) {
							continue;
						}

						float[] color = colorFor(state.getBlock());

						if (list == null) {
							list = new ArrayList<>();
						}

						list.add(new Light(worldX, worldY, worldZ, color[0], color[1], color[2], emission));
					}
				}
			}

			if (list != null) {
				found = list.toArray(NO_LIGHTS);
			}
		}

		Light[] old = sectionLights.get(key);

		if (found.length == 0) {
			if (old != null) {
				sectionLights.remove(key);
				lightsDirty = true;
			}
		} else if (old == null || !Arrays.equals(old, found)) {
			sectionLights.put(key, found);
			lightsDirty = true;
		}
	}

	/**
	 * True when all six neighbors also emit light. The inside of a lava lake or a glowstone wall
	 * would otherwise fill the whole list with lights nobody can tell apart.
	 */
	private boolean isInsideLightMass(ClientLevel level, int x, int y, int z) {
		for (Direction direction : DIRECTIONS) {
			neighbor.set(x + direction.getStepX(), y + direction.getStepY(), z + direction.getStepZ());

			if (level.getBlockState(neighbor).getLightEmission() <= 0) {
				return false;
			}
		}

		return true;
	}

	// Section keys: 22 bits chunk x, 22 bits chunk z, 20 bits section y, packed into a long.

	private static long sectionKey(int chunkX, int sectionY, int chunkZ) {
		return ((long) (chunkX & 0x3FFFFF) << 42) | ((long) (chunkZ & 0x3FFFFF) << 20) | (long) (sectionY & 0xFFFFF);
	}

	private static int keyChunkX(long key) {
		return (int) (key >> 42);
	}

	private static int keyChunkZ(long key) {
		return (int) ((key << 22) >> 42);
	}

	private static int keySectionY(long key) {
		return (int) ((key << 44) >> 44);
	}

	// ---- candidate list and grid ----

	/**
	 * Rebuilds the candidate list and the grid when the remembered lights changed (at most every
	 * MIN_REBUILD_FRAMES frames) or when the camera has moved far enough from the grid's center that
	 * the grid has to be re-centered (immediately). Between those events nothing here changes.
	 */
	private void refreshLists(Vector3d camera, int chunks) {
		int width = 2 * chunks + GRID_MARGIN_CELLS;
		int cameraCellX = Math.floorDiv((int) Math.floor(camera.x), CELL_SIZE);
		int cameraCellY = Math.floorDiv((int) Math.floor(camera.y), CELL_SIZE);
		int cameraCellZ = Math.floorDiv((int) Math.floor(camera.z), CELL_SIZE);

		boolean recenter = !gridValid
			|| chunks != gridChunks
			|| Math.abs(cameraCellX - (gridCellX + width / 2)) > RECENTER_SLACK
			|| Math.abs(cameraCellY - (gridCellY + GRID_Y / 2)) > RECENTER_SLACK
			|| Math.abs(cameraCellZ - (gridCellZ + width / 2)) > RECENTER_SLACK;

		framesSinceRebuild++;

		if (!recenter && !(lightsDirty && framesSinceRebuild >= MIN_REBUILD_FRAMES)) {
			return;
		}

		if (recenter) {
			gridChunks = chunks;
			gridWidth = width;
			gridCellX = cameraCellX - width / 2;
			gridCellY = cameraCellY - GRID_Y / 2;
			gridCellZ = cameraCellZ - width / 2;
			gridValid = true;
		}

		lightsDirty = false;
		framesSinceRebuild = 0;

		collectCandidates(camera, chunks);
		buildGrid();
	}

	/** Gathers the remembered lights that fall inside the grid, and forgets sections that are out of range. */
	private void collectCandidates(Vector3d camera, int chunks) {
		int cameraChunkX = Math.floorDiv((int) Math.floor(camera.x), 16);
		int cameraChunkZ = Math.floorDiv((int) Math.floor(camera.z), 16);
		int cameraSectionY = Math.floorDiv((int) Math.floor(camera.y), 16);

		int minX = gridCellX * CELL_SIZE;
		int maxX = (gridCellX + gridWidth) * CELL_SIZE;
		int minY = gridCellY * CELL_SIZE;
		int maxY = (gridCellY + GRID_Y) * CELL_SIZE;
		int minZ = gridCellZ * CELL_SIZE;
		int maxZ = (gridCellZ + gridWidth) * CELL_SIZE;

		ArrayList<Light> all = new ArrayList<>();
		Iterator<Long2ObjectMap.Entry<Light[]>> iterator = sectionLights.long2ObjectEntrySet().iterator();

		while (iterator.hasNext()) {
			Long2ObjectMap.Entry<Light[]> entry = iterator.next();
			long key = entry.getLongKey();

			if (Math.abs(keyChunkX(key) - cameraChunkX) > chunks + 1
				|| Math.abs(keyChunkZ(key) - cameraChunkZ) > chunks + 1
				|| Math.abs(keySectionY(key) - cameraSectionY) > SCAN_SECTIONS_Y + 1) {
				iterator.remove();
				continue;
			}

			for (Light light : entry.getValue()) {
				if (light.x() >= minX && light.x() < maxX
					&& light.y() >= minY && light.y() < maxY
					&& light.z() >= minZ && light.z() < maxZ) {
					all.add(light);
				}
			}
		}

		if (all.size() > MAX_CANDIDATES) {
			final double cx = camera.x;
			final double cy = camera.y;
			final double cz = camera.z;

			all.sort(Comparator.comparingDouble(light -> {
				double dx = light.x() + 0.5 - cx;
				double dy = light.y() + 0.5 - cy;
				double dz = light.z() + 0.5 - cz;
				return dx * dx + dy * dy + dz * dz;
			}));

			committed = all.subList(0, MAX_CANDIDATES).toArray(NO_LIGHTS);
		} else {
			committed = all.toArray(NO_LIGHTS);
		}
	}

	/** Sorts the candidate lights into the grid, writes candidates and grid into the staging buffer and uploads them. */
	private void buildGrid() {
		int cells = gridWidth * GRID_Y * gridWidth;
		Arrays.fill(gridCount, 0, cells, 0);

		double originX = gridCellX * CELL_SIZE;
		double originY = gridCellY * CELL_SIZE;
		double originZ = gridCellZ * CELL_SIZE;

		for (int index = 0; index < committed.length; index++) {
			Light light = committed[index];

			// Reach plus a little margin, so a surface right at a cell border still finds the light.
			double reach = light.level() + 1.0;
			double cx = light.x() + 0.5;
			double cy = light.y() + 0.5;
			double cz = light.z() + 0.5;

			int minX = Math.max(Math.floorDiv((int) Math.floor(cx - reach), CELL_SIZE) - gridCellX, 0);
			int maxX = Math.min(Math.floorDiv((int) Math.floor(cx + reach), CELL_SIZE) - gridCellX, gridWidth - 1);
			int minY = Math.max(Math.floorDiv((int) Math.floor(cy - reach), CELL_SIZE) - gridCellY, 0);
			int maxY = Math.min(Math.floorDiv((int) Math.floor(cy + reach), CELL_SIZE) - gridCellY, GRID_Y - 1);
			int minZ = Math.max(Math.floorDiv((int) Math.floor(cz - reach), CELL_SIZE) - gridCellZ, 0);
			int maxZ = Math.min(Math.floorDiv((int) Math.floor(cz + reach), CELL_SIZE) - gridCellZ, gridWidth - 1);

			double strength = (double) light.level() * light.level();

			for (int x = minX; x <= maxX; x++) {
				for (int y = minY; y <= maxY; y++) {
					for (int z = minZ; z <= maxZ; z++) {
						double dx = (gridCellX + x + 0.5) * CELL_SIZE - cx;
						double dy = (gridCellY + y + 0.5) * CELL_SIZE - cy;
						double dz = (gridCellZ + z + 0.5) * CELL_SIZE - cz;

						// Strong lights near the cell center matter most to the cell.
						float score = (float) (strength / (dx * dx + dy * dy + dz * dz + 64.0));
						insertIntoCell((x * GRID_Y + y) * gridWidth + z, index, score);
					}
				}
			}
		}

		// Candidates: positions relative to the grid corner, full strength (the grid has no cut-off to fade at).
		for (int i = 0; i < committed.length; i++) {
			writeLight(CANDIDATE_OFFSET + i * LIGHT_BYTES, committed[i], originX, originY, originZ, 1.0F);
		}

		// Grid cells: [count, indices...] each.
		for (int cell = 0; cell < cells; cell++) {
			int offset = GRID_OFFSET + cell * CELL_STRIDE_INTS * 4;
			int count = gridCount[cell];

			// Strongest first, so that at low level of detail the shader can use just the first few
			// lights of a cell (insertion sort of at most 15 entries, scores and indices together).
			int base = cell * CELL_LIGHTS;

			for (int a = 1; a < count; a++) {
				float score = gridScore[base + a];
				int lightIndex = gridIndex[base + a];
				int b = a - 1;

				while (b >= 0 && gridScore[base + b] < score) {
					gridScore[base + b + 1] = gridScore[base + b];
					gridIndex[base + b + 1] = gridIndex[base + b];
					b--;
				}

				gridScore[base + b + 1] = score;
				gridIndex[base + b + 1] = lightIndex;
			}

			staging.putInt(offset, count);

			for (int k = 0; k < count; k++) {
				staging.putInt(offset + 4 + k * 4, gridIndex[cell * CELL_LIGHTS + k]);
			}
		}

		uploadRange(CANDIDATE_OFFSET, CANDIDATE_OFFSET + committed.length * LIGHT_BYTES);
		uploadRange(GRID_OFFSET, GRID_OFFSET + cells * CELL_STRIDE_INTS * 4);
	}

	/** Adds a light to a cell, or replaces the cell's weakest light if the cell is full and this one beats it. */
	private void insertIntoCell(int cell, int lightIndex, float score) {
		int base = cell * CELL_LIGHTS;
		int count = gridCount[cell];

		if (count < CELL_LIGHTS) {
			gridIndex[base + count] = lightIndex;
			gridScore[base + count] = score;
			gridCount[cell] = count + 1;
			return;
		}

		int worst = 0;

		for (int k = 1; k < CELL_LIGHTS; k++) {
			if (gridScore[base + k] < gridScore[base + worst]) {
				worst = k;
			}
		}

		if (score > gridScore[base + worst]) {
			gridIndex[base + worst] = lightIndex;
			gridScore[base + worst] = score;
		}
	}

	// ---- halo list selection and upload ----

	// ---- halo list selection: ranking, view culling, hiding tests ----

	/**
	 * Fills picked/pickedScore with the lights that get a halo this frame and returns how many.
	 *
	 * Ranking: score is squared distance divided by squared strength, so a strong light farther away
	 * can beat a weak one that is nearer. Lower is better. Only lights inside the (widened) view are
	 * ranked. From the best RANK_CAP of them, hidden lights are dropped and the first MAX_LIGHTS that
	 * remain are used, still in score order.
	 */
	private int selectHaloLights(ClientLevel level, Vector3d camera) {
		frame++;

		boolean haveView = prepareView();
		int rankedCount = 0;

		for (Light light : committed) {
			if (haveView && !isInView(light, camera)) {
				continue;
			}

			double dx = light.x() + 0.5 - camera.x;
			double dy = light.y() + 0.5 - camera.y;
			double dz = light.z() + 0.5 - camera.z;
			double score = (dx * dx + dy * dy + dz * dz) / (double) (light.level() * light.level());

			// Level of detail: how big the visible part of the halo is on screen, in pixels.
			float detail = 1.0F;

			if (haveView) {
				double distance = Math.max(Math.sqrt(dx * dx + dy * dy + dz * dz), 0.5);
				double glowPixels = HALO_VISIBLE_SIGMAS * HALO_RADIUS_BLOCKS * (0.5 + light.level() / 15.0) / distance * pixelsPerRadian;
				detail = smoothstep(HALO_MIN_PIXELS, HALO_FULL_PIXELS, glowPixels);

				if (detail <= 0.02F) {
					continue;
				}
			}

			if (rankedCount == RANK_CAP && score >= rankedScore[RANK_CAP - 1]) {
				continue;
			}

			// Insertion sort into the ranked array (ascending score).
			int i = rankedCount == RANK_CAP ? RANK_CAP - 1 : rankedCount++;

			while (i > 0 && rankedScore[i - 1] > score) {
				ranked[i] = ranked[i - 1];
				rankedScore[i] = rankedScore[i - 1];
				rankedDetail[i] = rankedDetail[i - 1];
				i--;
			}

			ranked[i] = light;
			rankedScore[i] = score;
			rankedDetail[i] = detail;
		}

		int count = 0;
		int testsLeft = OCCLUSION_TESTS_PER_FRAME;

		for (int i = 0; i < rankedCount && count < MAX_LIGHTS; i++) {
			Light light = ranked[i];

			// A light that was never tested, or whose result is old, is tested now if the budget allows.
			// Until then it keeps its last result (visible, for a light that was never tested).
			if (frame - light.testFrame >= OCCLUSION_TTL_FRAMES && testsLeft > 0) {
				testsLeft--;
				light.hidden = isHidden(level, camera, light);
				light.testFrame = frame;
			}

			// Fade in quickly, out more slowly, so a light that flickers between two results does not pop.
			if (light.hidden) {
				light.visibility += (0.0F - light.visibility) * 0.12F;
			} else {
				light.visibility += (1.0F - light.visibility) * 0.25F;
			}

			if (light.visibility < 0.03F) {
				continue;
			}

			picked[count] = light;
			pickedScore[count] = rankedScore[i];
			pickedDetail[count] = rankedDetail[i];
			count++;
		}

		return count;
	}

	/** Radius in blocks of the part of a light that can show a halo: its block plus the visible part of the glow. */
	private static double glowRadius(Light light) {
		return 0.5 + 1.5 * (0.5 + light.level() / 15.0);
	}

	/**
	 * Takes the camera axes and field of view from the matrices Iris captured at the start of the
	 * frame. Returns false when they are not available yet (nothing is culled then).
	 */
	private boolean prepareView() {
		Matrix4fc view = CapturedRenderingState.INSTANCE.getGbufferModelView();
		Matrix4fc projection = CapturedRenderingState.INSTANCE.getGbufferProjection();

		if (view == null || projection == null || projection.m00() == 0.0F || projection.m11() == 0.0F) {
			return false;
		}

		// The view matrix turns world axes into view axes, so its rows are the camera's right, up and
		// backward directions in world space.
		rightX = view.m00();
		rightY = view.m10();
		rightZ = view.m20();
		upX = view.m01();
		upY = view.m11();
		upZ = view.m21();
		backX = view.m02();
		backY = view.m12();
		backZ = view.m22();

		// Half field of view on each axis, widened a little. Capped well below 90 degrees so tan stays finite.
		tanX = Math.tan(Math.min(Math.atan(1.0 / projection.m00()) + VIEW_SLACK_RADIANS, 1.45));
		tanY = Math.tan(Math.min(Math.atan(1.0 / projection.m11()) + VIEW_SLACK_RADIANS, 1.45));

		// Pixels per radian at the center of the view: the window height over the full vertical field
		// of view, using tan(half fov) = 1 / m11. The window height is in framebuffer pixels.
		pixelsPerRadian = Minecraft.getInstance().getWindow().getHeight() * projection.m11() / 2.0;
		return true;
	}

	private static float smoothstep(double edge0, double edge1, double x) {
		double t = Math.min(Math.max((x - edge0) / (edge1 - edge0), 0.0), 1.0);
		return (float) (t * t * (3.0 - 2.0 * t));
	}

	/** True if the light, with its glow, can be inside the widened view. */
	private boolean isInView(Light light, Vector3d camera) {
		double vx = light.x() + 0.5 - camera.x;
		double vy = light.y() + 0.5 - camera.y;
		double vz = light.z() + 0.5 - camera.z;

		double margin = glowRadius(light) + 1.0;
		double depth = -(vx * backX + vy * backY + vz * backZ);

		if (depth < -margin) {
			return false;
		}

		double ahead = Math.max(depth, 0.0);
		double side = vx * rightX + vy * rightY + vz * rightZ;
		double up = vx * upX + vy * upY + vz * upZ;

		return Math.abs(side) <= ahead * tanX + margin * 1.5 && Math.abs(up) <= ahead * tanY + margin * 1.5;
	}

	/**
	 * True only when the light cannot show a halo at all: rays to its middle and to eight points on a
	 * ring around it (the size of its glow, seen from the camera) are all stopped by solid blocks well
	 * before they get there. If any one of them gets through, the light is not hidden. That is what
	 * keeps a light that is behind a thin pole, or peeking around a corner, in the list.
	 */
	private boolean isHidden(ClientLevel level, Vector3d camera, Light light) {
		double cx = light.x() + 0.5;
		double cy = light.y() + 0.5;
		double cz = light.z() + 0.5;

		double dx = cx - camera.x;
		double dy = cy - camera.y;
		double dz = cz - camera.z;
		double distance = Math.sqrt(dx * dx + dy * dy + dz * dz);

		if (distance < OCCLUSION_MIN_DIST || distance > OCCLUSION_MAX_DIST) {
			return false;
		}

		if (!rayBlocked(level, camera.x, camera.y, camera.z, cx, cy, cz)) {
			return false;
		}

		// Two axes at right angles to the view ray, to lay the ring in.
		dx /= distance;
		dy /= distance;
		dz /= distance;

		double helperX = Math.abs(dy) < 0.9 ? 0.0 : 1.0;
		double helperY = Math.abs(dy) < 0.9 ? 1.0 : 0.0;

		double ux = dy * 0.0 - dz * helperY;
		double uy = dz * helperX - dx * 0.0;
		double uz = dx * helperY - dy * helperX;
		double uLength = Math.sqrt(ux * ux + uy * uy + uz * uz);
		ux /= uLength;
		uy /= uLength;
		uz /= uLength;

		double vx = dy * uz - dz * uy;
		double vy = dz * ux - dx * uz;
		double vz = dx * uy - dy * ux;

		double radius = glowRadius(light);

		for (int i = 0; i < 8; i++) {
			double angle = i * (Math.PI / 4.0);
			double a = Math.cos(angle) * radius;
			double b = Math.sin(angle) * radius;

			if (!rayBlocked(level, camera.x, camera.y, camera.z, cx + ux * a + vx * b, cy + uy * a + vy * b, cz + uz * a + vz * b)) {
				return false;
			}
		}

		return true;
	}

	/**
	 * Walks the blocks from the origin toward the target (a voxel grid walk) and returns true if an
	 * opaque full block is entered more than OCCLUSION_SURFACE_TOLERANCE before the target. Blocks
	 * that let light through (glass, leaves), blocks that are not full cubes (fences, slabs, panes)
	 * and chunks that are not loaded never block.
	 */
	private boolean rayBlocked(ClientLevel level, double ox, double oy, double oz, double tx, double ty, double tz) {
		double dx = tx - ox;
		double dy = ty - oy;
		double dz = tz - oz;
		double length = Math.sqrt(dx * dx + dy * dy + dz * dz);
		double limit = length - OCCLUSION_SURFACE_TOLERANCE;

		if (limit <= 0.0) {
			return false;
		}

		dx /= length;
		dy /= length;
		dz /= length;

		int bx = (int) Math.floor(ox);
		int by = (int) Math.floor(oy);
		int bz = (int) Math.floor(oz);

		int stepX = dx > 0.0 ? 1 : -1;
		int stepY = dy > 0.0 ? 1 : -1;
		int stepZ = dz > 0.0 ? 1 : -1;

		// Distance along the ray between two block borders on each axis, and to the first border.
		double deltaX = dx == 0.0 ? Double.POSITIVE_INFINITY : Math.abs(1.0 / dx);
		double deltaY = dy == 0.0 ? Double.POSITIVE_INFINITY : Math.abs(1.0 / dy);
		double deltaZ = dz == 0.0 ? Double.POSITIVE_INFINITY : Math.abs(1.0 / dz);

		double maxX = dx == 0.0 ? Double.POSITIVE_INFINITY : (dx > 0.0 ? bx + 1 - ox : ox - bx) * deltaX;
		double maxY = dy == 0.0 ? Double.POSITIVE_INFINITY : (dy > 0.0 ? by + 1 - oy : oy - by) * deltaY;
		double maxZ = dz == 0.0 ? Double.POSITIVE_INFINITY : (dz > 0.0 ? bz + 1 - oz : oz - bz) * deltaZ;

		// The block the origin is in is skipped; every block entered after it is tested.
		for (int steps = 0; steps < 512; steps++) {
			double entered;

			if (maxX < maxY && maxX < maxZ) {
				entered = maxX;
				bx += stepX;
				maxX += deltaX;
			} else if (maxY < maxZ) {
				entered = maxY;
				by += stepY;
				maxY += deltaY;
			} else {
				entered = maxZ;
				bz += stepZ;
				maxZ += deltaZ;
			}

			if (entered >= limit) {
				return false;
			}

			rayPos.set(bx, by, bz);
			BlockState state = level.getBlockState(rayPos);

			if (state.canOcclude() && state.isCollisionShapeFullBlock(level, rayPos)) {
				return true;
			}
		}

		return false;
	}

	/**
	 * Writes everything that changes every frame (header, grid size and origin, halo list) and
	 * uploads just that part of the buffer.
	 */
	private void uploadDynamic(int count, Vector3d camera) {
		staging.putInt(0, count).putInt(4, 0).putInt(8, 0).putInt(12, 0);

		staging.putInt(16, gridValid ? gridWidth : 0).putInt(20, gridValid ? GRID_Y : 0).putInt(24, gridValid ? gridWidth : 0).putInt(28, 0);

		staging.putFloat(32, (float) (gridCellX * CELL_SIZE - camera.x));
		staging.putFloat(36, (float) (gridCellY * CELL_SIZE - camera.y));
		staging.putFloat(40, (float) (gridCellZ * CELL_SIZE - camera.z));
		staging.putFloat(44, 0.0F);

		// When the halo list is full, the weakest lights are at the edge of the cut-off. Fade those
		// out instead of letting them switch on and off as the camera moves and the list reshuffles.
		double cutoff = count == MAX_LIGHTS ? pickedScore[MAX_LIGHTS - 1] : Double.POSITIVE_INFINITY;

		for (int i = 0; i < count; i++) {
			float weight = fadeWeight(pickedScore[i], cutoff) * picked[i].visibility * pickedDetail[i];
			// The weight goes into the color: every use of a halo light in the pack scales with it.
			writeLight(HALO_OFFSET + i * LIGHT_BYTES, picked[i], camera.x, camera.y, camera.z, weight);
		}

		uploadRange(0, HALO_END);
	}

	/** Uploads bytes [start, end) of the staging buffer to the same place in the GPU buffer. */
	private void uploadRange(int start, int end) {
		if (end <= start) {
			return;
		}

		staging.limit(end);
		staging.position(start);

		GlStateManager._glBindBuffer(GL43C.GL_SHADER_STORAGE_BUFFER, bufferId);
		GlStateManager._glBufferSubData(GL43C.GL_SHADER_STORAGE_BUFFER, start, staging);
		GlStateManager._glBindBuffer(GL43C.GL_SHADER_STORAGE_BUFFER, 0);

		// Back to the full buffer; the contents are untouched.
		staging.clear();
	}

	private void writeLight(int offset, Light light, double originX, double originY, double originZ, float weight) {
		staging.putFloat(offset, (float) (light.x() + 0.5 - originX));
		staging.putFloat(offset + 4, (float) (light.y() + 0.5 - originY));
		staging.putFloat(offset + 8, (float) (light.z() + 0.5 - originZ));
		staging.putFloat(offset + 12, light.level());

		staging.putFloat(offset + 16, light.r() * weight);
		staging.putFloat(offset + 20, light.g() * weight);
		staging.putFloat(offset + 24, light.b() * weight);
		staging.putFloat(offset + 28, light.level() / 15.0F);
	}

	/**
	 * 1 for lights well inside the cut-off, falling smoothly to 0 for the one at the cut-off.
	 * The fade covers the outer half of the score range.
	 */
	private static float fadeWeight(double score, double cutoff) {
		if (cutoff == Double.POSITIVE_INFINITY || cutoff <= 0.0) {
			return 1.0F;
		}

		double t = Math.min(Math.max((score - 0.5 * cutoff) / (0.5 * cutoff), 0.0), 1.0);
		return (float) (1.0 - t * t * (3.0 - 2.0 * t));
	}

	// ---- colors ----

	private float[] colorFor(Block block) {
		float[] color = colorCache.get(block);

		if (color == null) {
			color = resolveColor(BuiltInRegistries.BLOCK.getKey(block).getPath());
			colorCache.put(block, color);
		}

		return color;
	}

	/**
	 * Light color by block name. Matching is by substring, most specific first, so modded or newer
	 * blocks with familiar names (for example any "soul" light) get a sensible color without being
	 * listed. Anything unknown gets a warm white.
	 */
	private static float[] resolveColor(String path) {
		// Soul fire family: cyan-blue.
		if (path.contains("soul")) {
			return new float[]{0.35F, 0.78F, 1.00F};
		}

		// Redstone family: red.
		if (path.contains("redstone")) {
			return new float[]{1.00F, 0.28F, 0.22F};
		}

		// Sea lantern, conduit, beacon: cool white-blue.
		if (path.contains("sea_lantern") || path.contains("conduit") || path.contains("beacon")) {
			return new float[]{0.70F, 0.92F, 1.00F};
		}

		// End rod: pale lilac white.
		if (path.contains("end_rod")) {
			return new float[]{0.95F, 0.90F, 1.00F};
		}

		// Purple: amethyst, crying obsidian, portals, respawn anchor, ender chest.
		if (path.contains("amethyst") || path.contains("crying_obsidian") || path.contains("portal")
			|| path.contains("respawn_anchor") || path.contains("ender_chest")) {
			return new float[]{0.66F, 0.42F, 1.00F};
		}

		// Froglights.
		if (path.contains("verdant_froglight")) {
			return new float[]{0.55F, 1.00F, 0.55F};
		}
		if (path.contains("pearlescent_froglight")) {
			return new float[]{1.00F, 0.62F, 0.92F};
		}
		if (path.contains("ochre_froglight")) {
			return new float[]{1.00F, 0.86F, 0.42F};
		}

		// Sculk: teal.
		if (path.contains("sculk")) {
			return new float[]{0.30F, 0.82F, 0.90F};
		}

		// Plant light: glow lichen, cave vines with berries.
		if (path.contains("glow_lichen") || path.contains("cave_vines")) {
			return new float[]{0.85F, 0.95F, 0.55F};
		}

		// Lava and magma: red-hot. Little green and almost no blue, because blue next to red reads as pink.
		if (path.contains("lava") || path.contains("magma")) {
			return new float[]{1.00F, 0.34F, 0.07F};
		}

		// Glowstone and shroomlight: yellow / orange-yellow.
		if (path.contains("glowstone")) {
			return new float[]{1.00F, 0.84F, 0.45F};
		}
		if (path.contains("shroomlight")) {
			return new float[]{1.00F, 0.62F, 0.30F};
		}

		// Everything else (torches, lanterns, campfires, fire, candles, furnaces, jack o'lanterns): warm.
		return new float[]{1.00F, 0.78F, 0.46F};
	}
}
