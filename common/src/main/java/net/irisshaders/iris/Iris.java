package net.irisshaders.iris;

import com.google.common.base.Throwables;
import com.mojang.blaze3d.opengl.GlDebug;
import com.mojang.blaze3d.opengl.GlDevice;
import com.mojang.blaze3d.platform.InputConstants;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.vertex.DefaultVertexFormat;
import net.caffeinemc.mods.sodium.api.vertex.serializer.VertexSerializerRegistry;
import net.irisshaders.iris.compat.dh.DHCompat;
import net.irisshaders.iris.config.IrisConfig;
import net.irisshaders.iris.gl.GLDebug;
import net.irisshaders.iris.gl.buffer.ShaderStorageBufferHolder;
import net.irisshaders.iris.gl.shader.ShaderCompileException;
import net.irisshaders.iris.gl.shader.StandardMacros;
import net.irisshaders.iris.gui.debug.DebugLoadFailedGridScreen;
import net.irisshaders.iris.helpers.OptionalBoolean;
import net.irisshaders.iris.pbr.texture.PBRTextureManager;
import net.irisshaders.iris.pipeline.IrisRenderingPipeline;
import net.irisshaders.iris.pipeline.PipelineManager;
import net.irisshaders.iris.pipeline.VanillaRenderingPipeline;
import net.irisshaders.iris.pipeline.WorldRenderingPipeline;
import net.irisshaders.iris.platform.IrisPlatformHelpers;
import net.irisshaders.iris.shaderpack.DimensionId;
import net.irisshaders.iris.shaderpack.ShaderPack;
import net.irisshaders.iris.shaderpack.materialmap.NamespacedId;
import net.irisshaders.iris.shaderpack.option.OptionSet;
import net.irisshaders.iris.shaderpack.option.Profile;
import net.irisshaders.iris.shaderpack.option.values.MutableOptionValues;
import net.irisshaders.iris.shaderpack.option.values.OptionValues;
import net.irisshaders.iris.shaderpack.programs.ProgramSet;
import net.irisshaders.iris.uniforms.CapturedRenderingState;
import net.irisshaders.iris.vertices.IrisVertexFormats;
import net.irisshaders.iris.vertices.sodium.EntityToTerrainVertexSerializer;
import net.irisshaders.iris.vertices.sodium.GlyphExtVertexSerializer;
import net.irisshaders.iris.vertices.sodium.IrisEntityToTerrainVertexSerializer;
import net.irisshaders.iris.vertices.sodium.ModelToEntityVertexSerializer;
import net.minecraft.ChatFormatting;
import net.minecraft.SharedConstants;
import net.minecraft.util.Util;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.network.chat.ClickEvent;
import net.minecraft.network.chat.Component;
import net.minecraft.network.chat.HoverEvent;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.dimension.DimensionType;
import org.jetbrains.annotations.NotNull;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.ARBParallelShaderCompile;
import org.lwjgl.opengl.GL;
import org.lwjgl.opengl.KHRParallelShaderCompile;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.FileSystem;
import java.nio.file.FileSystemNotFoundException;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.InvalidPathException;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.util.Calendar;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Optional;
import java.util.Properties;
import java.util.stream.Stream;
import java.util.zip.ZipError;
import java.util.zip.ZipException;

public class Iris {
	public static final String MODID = "iris";

	/**
	 * The user-facing name of the mod. Moved into a constant to facilitate
	 * easy branding changes (for forks). You'll still need to change this
	 * separately in mixin plugin classes & the language files.
	 */
	public static final String MODNAME = "Iris";
	public static final IrisLogging logger = new IrisLogging(MODNAME);
	public static final boolean IS_FOOL;
	private static final Map<String, String> shaderPackOptionQueue = new HashMap<>();
	// Change this for snapshots!
	private static final String backupVersionNumber = "1.21.9";
	public static NamespacedId lastDimension = null;
	public static boolean testing = false;
	private static ShaderPack currentPack;
	private static final String BUILT_IN_SHADERS_PATH = "halilshaders/shaders";
	private static final String BUILT_IN_PACK_NAME = "HalilShaders";
	private static String currentPackName;
	private static Optional<Exception> storedError = Optional.empty();
	private static boolean initialized;
	private static PipelineManager pipelineManager;
	private static IrisConfig irisConfig;
	private static FileSystem zipFileSystem;
	private static KeyMapping reloadKeybind;
	private static final KeyMapping.Category irisKeybindCategory = KeyMapping.Category.register(Identifier.fromNamespaceAndPath("iris", "keybinds"));
	private static KeyMapping toggleShadersKeybind;
	private static KeyMapping wireframeKeybind;
	// Flag variable used when reloading
	// Used in favor of queueDefaultShaderPackOptionValues() for resetting as the
	// behavior is more concrete and therefore is more likely to repair a user's issues
	private static boolean resetShaderPackOptions = false;
	private static String IRIS_VERSION;
	private static UpdateChecker updateChecker;
	private static boolean fallback;
	private static boolean loadShaderPackWhenPossible;

	static {
		if (!BuildConfig.ACTIVATE_RENDERDOC && IrisPlatformHelpers.getInstance().isDevelopmentEnvironment() && System.getProperty("user.name").contains("ims") && Util.getPlatform() == Util.OS.LINUX) {
		}

		Calendar c = Calendar.getInstance();
		IS_FOOL = c.get(Calendar.MONTH) == Calendar.APRIL && c.get(Calendar.DAY_OF_MONTH) == 1;
	}

	/**
	 * Called once RenderSystem#initRenderer has completed. This means that we can safely access OpenGL.
	 */
	public static void onRenderSystemInit() {
		if (!initialized) {
			Iris.logger.warn("Iris::onRenderSystemInit was called, but Iris::onEarlyInitialize was not called." +
				" Trying to avoid a crash but this is an odd state.");
			return;
		}

		if (GL.getCapabilities().GL_KHR_parallel_shader_compile) {
			KHRParallelShaderCompile.glMaxShaderCompilerThreadsKHR(10);
		} else if (GL.getCapabilities().GL_ARB_parallel_shader_compile) {
			ARBParallelShaderCompile.glMaxShaderCompilerThreadsARB(10);
		}

		PBRTextureManager.INSTANCE.init();

		VertexSerializerRegistry.instance().registerSerializer(DefaultVertexFormat.NEW_ENTITY, IrisVertexFormats.TERRAIN, new EntityToTerrainVertexSerializer());
		VertexSerializerRegistry.instance().registerSerializer(IrisVertexFormats.ENTITY, IrisVertexFormats.TERRAIN, new IrisEntityToTerrainVertexSerializer());
		VertexSerializerRegistry.instance().registerSerializer(DefaultVertexFormat.POSITION_COLOR_TEX_LIGHTMAP, IrisVertexFormats.GLYPH, new GlyphExtVertexSerializer());
		VertexSerializerRegistry.instance().registerSerializer(DefaultVertexFormat.NEW_ENTITY, IrisVertexFormats.ENTITY, new ModelToEntityVertexSerializer());

		// Only load the shader pack when we can access OpenGL
		if (!IrisPlatformHelpers.getInstance().isModLoaded("distanthorizons")) {
			loadShaderpack();
		}
	}

	public static void duringRenderSystemInit() {
		setDebug(irisConfig.areDebugOptionsEnabled());
	}

	/**
	 * Called when the title screen is initialized for the first time.
	 */
	public static void onLoadingComplete() {
		if (!initialized) {
			Iris.logger.warn("Iris::onLoadingComplete was called, but Iris::onEarlyInitialize was not called." +
				" Trying to avoid a crash but this is an odd state.");
			return;
		}

		// Initialize the pipeline now so that we don't increase world loading time. Just going to guess that
		// the player is in the overworld.
		// See: https://github.com/IrisShaders/Iris/issues/323
		lastDimension = DimensionId.OVERWORLD;
		Iris.getPipelineManager().preparePipeline(DimensionId.OVERWORLD);
	}

	public static void handleKeybinds(Minecraft minecraft) {
		if (loadShaderPackWhenPossible) {
			loadShaderPackWhenPossible = false;
			Iris.loadShaderpack();
		}

		if (reloadKeybind.consumeClick()) {
			try {
				reload();

				if (minecraft.player != null) {
					minecraft.player.displayClientMessage(Component.translatable("iris.shaders.reloaded"), false);
				}

			} catch (Exception e) {
				logger.error("Error while reloading Shaders for Iris!", e);

				if (minecraft.player != null) {
					minecraft.player.displayClientMessage(Component.translatable("iris.shaders.reloaded.failure", Throwables.getRootCause(e).getMessage()).withStyle(ChatFormatting.RED), false);
				}
			}
		} else if (toggleShadersKeybind.consumeClick()) {
			try {
				toggleShaders(minecraft, !irisConfig.areShadersEnabled());
			} catch (Exception e) {
				logger.error("Error while toggling shaders!", e);

				if (minecraft.player != null) {
					minecraft.player.displayClientMessage(Component.translatable("iris.shaders.toggled.failure", Throwables.getRootCause(e).getMessage()).withStyle(ChatFormatting.RED), false);
				}
				setShadersDisabled();
				fallback = true;
			}
		} else if (wireframeKeybind.consumeClick()) {
			if (irisConfig.areDebugOptionsEnabled() && minecraft.player != null && !Minecraft.getInstance().isLocalServer()) {
				minecraft.player.displayClientMessage(Component.literal("No cheating; wireframe only in singleplayer!"), false);
			}
		}
	}

	public static boolean shouldActivateWireframe() {
		return irisConfig.areDebugOptionsEnabled() && wireframeKeybind.isDown();
	}

	public static void toggleShaders(Minecraft minecraft, boolean enabled) throws IOException {
		irisConfig.setShadersEnabled(enabled);
		irisConfig.save();

		reload();
		if (minecraft.player != null) {
			minecraft.player.displayClientMessage(enabled ? Component.translatable("iris.shaders.toggled", currentPackName) : Component.translatable("iris.shaders.disabled"), false);
		}
	}

	public static void loadShaderpack() {
		if (irisConfig == null) {
			if (!initialized) {
				throw new IllegalStateException("Iris::loadShaderpack was called, but Iris::onInitializeClient wasn't" +
					" called yet. How did this happen?");
			} else {
				throw new NullPointerException("Iris.irisConfig was null unexpectedly");
			}
		}

		if (!irisConfig.areShadersEnabled()) {
			logger.info("Shaders are disabled because enableShaders is set to false in iris.properties");

			setShadersDisabled();

			return;
		}

		if (!loadBuiltInShaderpack()) {
			logger.warn("Falling back to normal rendering without shaders because the built-in shaderpack could not be loaded");
			setShadersDisabled();
			fallback = true;
		}
	}

	/**
	 * HalilShaders ships its shaders inside the mod (resources under {@link #BUILT_IN_SHADERS_PATH}).
	 * There is no pack discovery or selection; this is the only source of shaders.
	 *
	 * @return false if loading failed, true otherwise (including "no built-in shaders present", which leaves shaders off)
	 */
	private static boolean loadBuiltInShaderpack() {
		Optional<Path> shaderPackPath = IrisPlatformHelpers.getInstance().findModResource(BUILT_IN_SHADERS_PATH);

		if (shaderPackPath.isEmpty() || !Files.isDirectory(shaderPackPath.get())) {
			logger.info("No built-in shaders found at \"{}\"; shaders are disabled", BUILT_IN_SHADERS_PATH);
			setShadersDisabled();
			return true;
		}

		Path root = shaderPackPath.get();
		// A path inside the mod jar lives on a zip filesystem; a dev-environment resources dir does not.
		boolean isZip = root.getFileSystem() != FileSystems.getDefault();

		Map<String, String> changedConfigs = new HashMap<>(shaderPackOptionQueue);
		clearShaderPackOptionQueue();

		if (resetShaderPackOptions) {
			changedConfigs.clear();
		}
		resetShaderPackOptions = false;

		try {
			currentPack = new ShaderPack(root, changedConfigs, StandardMacros.createStandardEnvironmentDefines(), isZip);
		} catch (Exception e) {
			logger.error("Failed to load the built-in shaderpack!", e);
			handleException(e);

			return false;
		}

		fallback = false;
		currentPackName = BUILT_IN_PACK_NAME;

		logger.info("Using built-in shaderpack: " + BUILT_IN_PACK_NAME);

		return true;
	}

	private static void handleException(Exception e) {
		if (irisConfig.areDebugOptionsEnabled()) {
			Minecraft.getInstance().setScreen(new DebugLoadFailedGridScreen(Minecraft.getInstance().screen, Component.literal(e instanceof ShaderCompileException ? "Failed to compile shaders" : "Exception"), e));
		} else {
			if (Minecraft.getInstance().player != null) {
				Minecraft.getInstance().player.displayClientMessage(Component.translatable(e instanceof ShaderCompileException ? "iris.load.failure.shader" : "iris.load.failure.generic").append(Component.literal("Copy Info").withStyle(arg -> arg.withUnderlined(true).withColor(
					ChatFormatting.BLUE).withClickEvent(new ClickEvent.CopyToClipboard(e.getMessage())).withHoverEvent(new HoverEvent.ShowText(Component.translatable("chat.copy.click"))))), false);
			} else {
				storedError = Optional.of(e);
			}
		}
	}

	private static void setShadersDisabled() {
		currentPack = null;
		fallback = false;
		currentPackName = "(off)";
	}

	public static void setDebug(boolean enable) {
		try {
			irisConfig.setDebugEnabled(enable);
			irisConfig.save();
		} catch (IOException e) {
			Iris.logger.fatal("Failed to save config!", e);
		}

		int success;
		if (enable) {
			success = GLDebug.setupDebugMessageCallback();
		} else {
			GLDebug.reloadDebugState();
			GlDebug.enableDebugCallback(Minecraft.getInstance().options.glDebugVerbosity, false, new HashSet<>(((GlDevice) RenderSystem.getDevice()).getEnabledExtensions()));
			success = 1;
		}

		logger.info("Debug functionality is " + (enable ? "enabled, logging will be more verbose!" : "disabled."));
		if (Minecraft.getInstance().player != null) {
			if (IrisPlatformHelpers.getInstance().useELS()) {
				Minecraft.getInstance().player.displayClientMessage(Component.translatable("iris.shaders.debug.restartNoDebug"), false);
			} else {
				Minecraft.getInstance().player.displayClientMessage(Component.translatable(success != 0 ? (enable ? "iris.shaders.debug.enabled" : "iris.shaders.debug.disabled") : "iris.shaders.debug.failure"), false);
			}

			if (success == 2 && !IrisPlatformHelpers.getInstance().useELS()) {
				Minecraft.getInstance().player.displayClientMessage(Component.translatable("iris.shaders.debug.restart"), false);
			}
		}
	}

	private static Optional<Properties> tryReadConfigProperties(Path path) {
		Properties properties = new Properties();

		if (Files.exists(path)) {
			try (InputStream is = Files.newInputStream(path)) {
				// NB: config properties are specified to be encoded with ISO-8859-1 by OptiFine,
				//     so we don't need to do the UTF-8 workaround here.
				properties.load(is);
			} catch (IOException e) {
				// TODO: Better error handling
				return Optional.empty();
			}
		}

		return Optional.of(properties);
	}

	private static void tryUpdateConfigPropertiesFile(Path path, Properties properties) {
		try {
			if (properties.isEmpty()) {
				// Delete the file or don't create it if there are no changed configs
				if (Files.exists(path)) {
					Files.delete(path);
				}

				return;
			}

			try (OutputStream out = Files.newOutputStream(path)) {
				properties.store(out, null);
			}
		} catch (IOException e) {
			// TODO: Better error handling
		}
	}

	public static Map<String, String> getShaderPackOptionQueue() {
		return shaderPackOptionQueue;
	}

	public static void queueShaderPackOptionsFromProfile(Profile profile) {
		getShaderPackOptionQueue().putAll(profile.optionValues);
	}

	public static void queueShaderPackOptionsFromProperties(Properties properties) {
		queueDefaultShaderPackOptionValues();

		properties.stringPropertyNames().forEach(key ->
			getShaderPackOptionQueue().put(key, properties.getProperty(key)));
	}

	// Used in favor of resetShaderPackOptions as the aforementioned requires the pack to be reloaded
	public static void queueDefaultShaderPackOptionValues() {
		clearShaderPackOptionQueue();

		getCurrentPack().ifPresent(pack -> {
			OptionSet options = pack.getShaderPackOptions().getOptionSet();
			OptionValues values = pack.getShaderPackOptions().getOptionValues();

			options.getStringOptions().forEach((key, mOpt) -> {
				if (values.getStringValue(key).isPresent()) {
					getShaderPackOptionQueue().put(key, mOpt.getOption().getDefaultValue());
				}
			});
			options.getBooleanOptions().forEach((key, mOpt) -> {
				if (values.getBooleanValue(key) != OptionalBoolean.DEFAULT) {
					getShaderPackOptionQueue().put(key, Boolean.toString(mOpt.getOption().getDefaultValue()));
				}
			});
		});
	}

	public static void clearShaderPackOptionQueue() {
		getShaderPackOptionQueue().clear();
	}

	public static void resetShaderPackOptionsOnNextReload() {
		resetShaderPackOptions = true;
	}

	public static boolean shouldResetShaderPackOptionsOnNextReload() {
		return resetShaderPackOptions;
	}

	public static void reload() throws IOException {
		// allows shaderpacks to be changed at runtime
		irisConfig.initialize();

		// Reset the texture reload counter
		CapturedRenderingState.INSTANCE.resetTextureReloadCount();

		// Destroy all allocated resources
		destroyEverything();

		// Load the new shaderpack
		loadShaderpack();

		// Very important - we need to re-create the pipeline straight away.
		// https://github.com/IrisShaders/Iris/issues/1330
		if (Minecraft.getInstance().level != null) {
			Iris.getPipelineManager().preparePipeline(Iris.getCurrentDimension());
		}
	}

	/**
	 * Destroys and deallocates all created OpenGL resources. Useful as part of a reload.
	 */
	private static void destroyEverything() {
		currentPack = null;

		getPipelineManager().destroyPipeline();

		// Close the zip filesystem that the shaderpack was loaded from
		//
		// This prevents a FileSystemAlreadyExistsException when reloading shaderpacks.
		if (zipFileSystem != null) {
			try {
				zipFileSystem.close();
			} catch (NoSuchFileException e) {
				logger.warn("Failed to close the shaderpack zip when reloading because it was deleted, proceeding anyways.");
			} catch (IOException e) {
				logger.error("Failed to close zip file system?", e);
			}
		}
	}

	public static NamespacedId getCurrentDimension() {
		ClientLevel level = Minecraft.getInstance().level;

		if (level != null) {
			NamespacedId dimensionId = new NamespacedId(level.dimension().identifier().getNamespace(), level.dimension().identifier().getPath());

			ShaderPack pack = getCurrentPack().orElse(null);

			// If there is an exact match in dimension.properties, don't override using dimension type effects
			if (pack != null && pack.getDimensionMap().containsKey(dimensionId)) {
				return dimensionId;
			}

			// Check if the dimension type of the current level has a custom skybox set (end sky or overworld).
			// This is OVERWORLD by default, but can also be END or NONE.
			// The appropriate shader for the dimension should be used by default in order to prevent buggy results.
			// More information at https://minecraft.wiki/w/Dimension_type
			// https://github.com/IrisShaders/Iris/issues/2200
			DimensionType.Skybox skybox = level.dimensionType().skybox();

			if (skybox == DimensionType.Skybox.END) {
				return DimensionId.END;
			}

			if (skybox == DimensionType.Skybox.OVERWORLD) {
				return DimensionId.OVERWORLD;
			}

			return dimensionId;
		} else {
			// This prevents us from reloading the shaderpack unless we need to. Otherwise, if the player is in the
			// nether and quits the game, we might end up reloading the shaders on exit and on entry to the level
			// because the code thinks that the dimension changed.
			return lastDimension;
		}
	}

	private static WorldRenderingPipeline createPipeline(NamespacedId dimensionId) {
		if (currentPack == null) {
			// Completely disables shader-based rendering
			return new VanillaRenderingPipeline();
		}

		ProgramSet programs = currentPack.getProgramSet(dimensionId);

		// We use DeferredWorldRenderingPipeline on 1.16, and NewWorldRendering pipeline on 1.17 when rendering shaders.
		try {
			return new IrisRenderingPipeline(programs);
		} catch (Exception e) {
			handleException(e);

			ShaderStorageBufferHolder.forceDeleteBuffers();
			logger.error("Failed to create shader rendering pipeline, disabling shaders!", e);
			// TODO: This should be reverted if a dimension change causes shaders to compile again
			fallback = true;

			return new VanillaRenderingPipeline();
		}
	}

	@NotNull
	public static PipelineManager getPipelineManager() {
		if (pipelineManager == null) {
			pipelineManager = new PipelineManager(Iris::createPipeline);
		}

		return pipelineManager;
	}

	public static Optional<Exception> getStoredError() {
		Optional<Exception> stored = Iris.storedError;
		storedError = Optional.empty();
		return stored;
	}

	@NotNull
	public static Optional<ShaderPack> getCurrentPack() {
		return Optional.ofNullable(currentPack);
	}

	public static String getCurrentPackName() {
		return currentPackName;
	}

	public static IrisConfig getIrisConfig() {
		return irisConfig;
	}

	public static UpdateChecker getUpdateChecker() {
		return updateChecker;
	}

	public static boolean isFallback() {
		return fallback;
	}

	public static String getVersion() {
		if (IRIS_VERSION == null) {
			return "Version info unknown!";
		}

		return IRIS_VERSION;
	}

	public static String getFormattedVersion() {
		ChatFormatting color;
		String version = getVersion();

		if (IrisPlatformHelpers.getInstance().isDevelopmentEnvironment()) {
			color = ChatFormatting.GOLD;
			version = version + " (Development Environment)";
		} else if (version.endsWith("-dirty") || version.contains("unknown") || version.endsWith("-nogit")) {
			color = ChatFormatting.RED;
		} else if (version.contains("+rev.")) {
			color = ChatFormatting.LIGHT_PURPLE;
		} else {
			color = ChatFormatting.GREEN;
		}

		return color + version;
	}

	/**
	 * Gets the current release target. Since 1.19.3, Mojang no longer stores this information, so we must manually provide it for snapshots.
	 *
	 * @return Release target
	 */
	public static String getReleaseTarget() {
		// If this is a snapshot, you must change backupVersionNumber!
		SharedConstants.tryDetectVersion();
		return SharedConstants.getCurrentVersion().stable() ? SharedConstants.getCurrentVersion().name() : backupVersionNumber;
	}

	public static String getBackupVersionNumber() {
		return backupVersionNumber;
	}

	public static boolean loadedIncompatiblePack() {
		return DHCompat.lastPackIncompatible();
	}

	public static boolean isPackInUseQuick() {
		return getPipelineManager().getPipelineNullable() instanceof IrisRenderingPipeline;
	}

	public static void loadShaderpackWhenPossible() {
		loadShaderPackWhenPossible = true;
	}

	public static String getVersionSimple() {
		return getVersion().split("\\+")[0];
	}

    /**
	 * Called very early on in Minecraft initialization. At this point we *cannot* safely access OpenGL, but we can do
	 * some very basic setup, config loading, and environment checks.
	 *
	 * <p>This is roughly equivalent to Fabric Loader's ClientModInitializer#onInitializeClient entrypoint, except
	 * it's entirely cross platform & we get to decide its exact semantics.</p>
	 *
	 * <p>This is called right before options are loaded, so we can add key bindings here.</p>
	 */
	public void onEarlyInitialize() {
		IRIS_VERSION = IrisPlatformHelpers.getInstance().getVersion();

		updateChecker = new UpdateChecker(IRIS_VERSION);

		reloadKeybind = IrisPlatformHelpers.getInstance().registerKeyBinding(new KeyMapping("iris.keybind.reload", InputConstants.Type.KEYSYM, GLFW.GLFW_KEY_R, irisKeybindCategory));
		toggleShadersKeybind = IrisPlatformHelpers.getInstance().registerKeyBinding(new KeyMapping("iris.keybind.toggleShaders", InputConstants.Type.KEYSYM, GLFW.GLFW_KEY_K, irisKeybindCategory));
		wireframeKeybind = IrisPlatformHelpers.getInstance().registerKeyBinding(new KeyMapping("iris.keybind.wireframe", InputConstants.Type.KEYSYM, InputConstants.UNKNOWN.getValue(), irisKeybindCategory));

		DHCompat.run();

		irisConfig = new IrisConfig(IrisPlatformHelpers.getInstance().getConfigDir().resolve("iris.properties"), IrisPlatformHelpers.getInstance().getConfigDir().resolve("iris-excluded.json"));

		try {
			irisConfig.initialize();
		} catch (IOException e) {
			logger.error("Failed to initialize Iris configuration, default values will be used instead");
			logger.error("", e);
		}

		updateChecker.checkForUpdates(irisConfig);

		initialized = true;
	}
}
