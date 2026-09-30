/*
 * Alpha NTP wallpaper injection for Brave (issue #13).
 *
 * Brave's New tab page settings only expose "Show background images".
 * Native branded wallpapers are URL-loaded in libchrome.so and ignore
 * android.resource:// URIs. The Java ambient catalog (t9i-style) instead
 * holds an Android drawable resource id on BackgroundImage.a and is decoded
 * with Resources — that is the path this patch owns:
 *   1) rewrite the no-arg BackgroundImage factory to return our drawable
 *   2) force wallpaper callbacks to use that factory instead of native data
 */
package app.morphe.patches.brave

import app.morphe.patcher.Fingerprint
import app.morphe.patcher.extensions.InstructionExtensions.addInstructions
import app.morphe.patcher.extensions.InstructionExtensions.removeInstructions
import app.morphe.patcher.patch.ApkFileType
import app.morphe.patcher.patch.AppTarget
import app.morphe.patcher.patch.BytecodePatch
import app.morphe.patcher.patch.Compatibility
import app.morphe.patcher.patch.PatchException
import app.morphe.patcher.patch.ResourcePatch
import app.morphe.patcher.patch.bytecodePatch
import app.morphe.patcher.patch.resourcePatch
import app.morphe.patcher.patch.stringOption
import com.android.tools.smali.dexlib2.iface.ClassDef
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction
import com.android.tools.smali.dexlib2.iface.reference.FieldReference
import com.android.tools.smali.dexlib2.iface.reference.MethodReference
import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream

internal const val NTP_WALLPAPER_RESOURCE_NAME = "morphe_custom_ntp_wallpaper"
internal const val NTP_WALLPAPER_PREFIX = "ntp_wallpaper_"
internal const val NTP_BACKGROUND_IMAGES_BRIDGE =
    "Lorg/chromium/chrome/browser/ntp_background_images/NTPBackgroundImagesBridge;"
internal const val BACKGROUND_IMAGE_MODEL =
    "Lorg/chromium/chrome/browser/ntp_background_images/model/BackgroundImage;"
internal const val WALLPAPER_MODEL =
    "Lorg/chromium/chrome/browser/ntp_background_images/model/Wallpaper;"

internal const val MIN_WALLPAPER_DIMENSION = 480
internal const val MAX_WALLPAPER_DIMENSION = 8192
internal const val MAX_WALLPAPER_FILE_SIZE = 8L * 1024L * 1024L

internal data class WallpaperDimensions(
    val width: Int,
    val height: Int,
)

internal object CreateWallpaperFingerprint : Fingerprint(
    definingClass = NTP_BACKGROUND_IMAGES_BRIDGE,
    name = "createWallpaper",
    returnType = BACKGROUND_IMAGE_MODEL,
    parameters = listOf("Ljava/lang/String;", "Ljava/lang/String;", "Ljava/lang/String;"),
)

internal object CreateBrandedWallpaperFingerprint : Fingerprint(
    definingClass = NTP_BACKGROUND_IMAGES_BRIDGE,
    name = "createBrandedWallpaper",
    returnType = WALLPAPER_MODEL,
    parameters = listOf(
        "Ljava/lang/String;",
        "I",
        "I",
        "Ljava/lang/String;",
        "Ljava/lang/String;",
        "Z",
        "Ljava/lang/String;",
        "Ljava/lang/String;",
        "Z",
        "I",
    ),
)

/**
 * Ambient Java catalog accessor (`t9i.a()` on inspected builds): static no-arg
 * factory returning BackgroundImage, owning class <clinit> IPUTs a drawable
 * resource id into BackgroundImage. Unique anchor independent of the obfuscated
 * class name.
 */
internal object AmbientCatalogAccessorFingerprint : Fingerprint(
    returnType = BACKGROUND_IMAGE_MODEL,
    parameters = emptyList(),
    custom = { _, classDef ->
        classDef.methods.any { method ->
            if (method.name != "<clinit>") return@any false
            val impl = method.implementation ?: return@any false
            impl.instructions.any { ins ->
                val field = (ins as? ReferenceInstruction)?.reference as? FieldReference
                field != null &&
                    field.definingClass == BACKGROUND_IMAGE_MODEL &&
                    field.type == "I"
            }
        }
    },
)

internal fun backgroundImageResourceIdField(classDef: ClassDef): String {
    val clinit = classDef.methods.firstOrNull { it.name == "<clinit>" && it.implementation != null }
        ?: error("ambient wallpaper catalog class has no <clinit>")
    val field = clinit.implementation!!.instructions
        .mapNotNull { (it as? ReferenceInstruction)?.reference as? FieldReference }
        .firstOrNull { it.definingClass == BACKGROUND_IMAGE_MODEL && it.type == "I" }
        ?: error("BackgroundImage resource-id field not found in catalog <clinit>")
    return "${field.definingClass}->${field.name}:${field.type}"
}

internal const val NTP_WALLPAPER_HELPER =
    "Lapp/morphe/extension/brave/NtpWallpaperIds;"

/**
 * Replaces the ambient catalog accessor. MUST fit in the original tiny
 * register file (inspected `edi.a()` has only 3 regs: v0–v2).
 * `getIdentifier` is 4-arg and `R$drawable` is stripped / wrong package after
 * rename — both crashed. Extension helper + 2-reg invoke-static is the only
 * path that fits and resolves at runtime.
 */
internal fun forceAmbientCatalogAccessorSmali(
    resourceIdField: String,
    wallpaperCount: Int = 1,
): String = if (wallpaperCount > 1) {
    """
    const/16 v0, $wallpaperCount
    invoke-static {v0}, $NTP_WALLPAPER_HELPER->drawableId(I)I
    move-result v0
    new-instance v1, $BACKGROUND_IMAGE_MODEL
    invoke-direct {v1}, $BACKGROUND_IMAGE_MODEL-><init>()V
    iput v0, v1, $resourceIdField
    return-object v1
    """.trimIndent()
} else {
    """
    invoke-static {}, $NTP_WALLPAPER_HELPER->drawableId()I
    move-result v0
    new-instance v1, $BACKGROUND_IMAGE_MODEL
    invoke-direct {v1}, $BACKGROUND_IMAGE_MODEL-><init>()V
    iput v0, v1, $resourceIdField
    return-object v1
    """.trimIndent()
}

/**
 * Callback.onResult(Object) on wallpaper delivery sites: replace the native
 * wallpaper object with the ambient catalog accessor result so Brave's
 * branded/URL wallpapers never win. p1 is the sole parameter (p0 = this).
 */
internal fun forceUseAmbientCatalogSmali(
    catalogClass: String,
    catalogMethod: String,
): String = """
    invoke-static {}, $catalogClass->$catalogMethod()$BACKGROUND_IMAGE_MODEL
    move-result-object p1
""".trimIndent()

/**
 * `android.resource://<package>/drawable/ntp_wallpaper_<index>`.
 * Package name is baked at patch time (apps may be renamed, e.g. Origin Nightly).
 */
internal fun ntpWallpaperResourceUri(packageName: String, index: Int = 0): String =
    "android.resource://$packageName/drawable/ntp_wallpaper_$index"

/**
 * Overwrites createWallpaper(String, String, String) params then falls through.
 * Generates a random index in [0, N-1] using java.util.Random and constructs the dynamic
 * resource URI: "android.resource://$packageName/drawable/ntp_wallpaper_$index".
 * Only touches p0-p2 (all String) — never v0/v1/v2, which alias params on tight methods.
 */
internal fun forceCreateWallpaperParamsSmali(
    packageName: String,
    wallpaperCount: Int = 1,
): String = """
    new-instance p0, Ljava/util/Random;
    invoke-direct {p0}, Ljava/util/Random;-><init>()V
    const/16 p1, ${if (wallpaperCount > 1) wallpaperCount else 1}
    invoke-virtual {p0, p1}, Ljava/util/Random;->nextInt(I)I
    move-result p0
    invoke-static {p0}, Ljava/lang/String;->valueOf(I)Ljava/lang/String;
    move-result-object p0
    const-string p1, "ntp_wallpaper_"
    invoke-virtual {p1, p0}, Ljava/lang/String;->concat(Ljava/lang/String;)Ljava/lang/String;
    move-result-object p2
    const-string p1, "android.resource://$packageName/drawable/"
    invoke-virtual {p1, p2}, Ljava/lang/String;->concat(Ljava/lang/String;)Ljava/lang/String;
    move-result-object p1
    move-object p0, p2
    const-string p2, "Custom"
""".trimIndent()

/**
 * Overwrites createBrandedWallpaper string params (id + URL/credit slots) then
 * falls through. Generates a random index in [0, N-1] and builds dynamic resource URI.
 * CRITICAL: p1/p2/p5/p8/p9 are int/boolean and on a 10-param static method they
 * alias v1.. — ONLY touches String registers p0, p3, p4, p6, p7 to avoid ART VerifyError.
 */
internal fun forceCreateBrandedWallpaperParamsSmali(
    packageName: String,
    wallpaperCount: Int = 1,
): String = """
    new-instance p0, Ljava/util/Random;
    invoke-direct {p0}, Ljava/util/Random;-><init>()V
    const/16 p3, ${if (wallpaperCount > 1) wallpaperCount else 1}
    invoke-virtual {p0, p3}, Ljava/util/Random;->nextInt(I)I
    move-result p0
    invoke-static {p0}, Ljava/lang/String;->valueOf(I)Ljava/lang/String;
    move-result-object p0
    const-string p3, "ntp_wallpaper_"
    invoke-virtual {p3, p0}, Ljava/lang/String;->concat(Ljava/lang/String;)Ljava/lang/String;
    move-result-object p0
    const-string p3, "android.resource://$packageName/drawable/"
    invoke-virtual {p3, p0}, Ljava/lang/String;->concat(Ljava/lang/String;)Ljava/lang/String;
    move-result-object p3
    move-object p4, p3
    move-object p6, p3
    move-object p7, p3
""".trimIndent()

internal fun validateWallpaperFile(file: File): WallpaperDimensions {
    if (!file.exists()) {
        throw PatchException("Custom NTP wallpaper file does not exist: ${file.absolutePath}")
    }
    if (!file.isFile || !file.canRead()) {
        throw PatchException("Custom NTP wallpaper file is not readable: ${file.absolutePath}")
    }
    if (file.length() > MAX_WALLPAPER_FILE_SIZE) {
        throw PatchException(
            "Custom NTP wallpaper exceeds 8 MiB: ${file.absolutePath}",
        )
    }
    val dimensions = readPngDimensions(file)
        ?: throw PatchException("Custom NTP wallpaper must be a valid PNG file: ${file.absolutePath}")
    if (dimensions.width !in MIN_WALLPAPER_DIMENSION..MAX_WALLPAPER_DIMENSION ||
        dimensions.height !in MIN_WALLPAPER_DIMENSION..MAX_WALLPAPER_DIMENSION
    ) {
        throw PatchException(
            "Custom NTP wallpaper must be between $MIN_WALLPAPER_DIMENSION and " +
                "$MAX_WALLPAPER_DIMENSION px on each side, received " +
                "${dimensions.width}x${dimensions.height}",
        )
    }
    return dimensions
}

internal fun validateWallpaperFiles(files: List<File>): List<WallpaperDimensions> {
    if (files.isEmpty()) {
        throw PatchException("No wallpaper files provided")
    }
    return files.map { validateWallpaperFile(it) }
}

internal fun resolveWallpaperFiles(sourcePath: String): List<File> {
    val trimmed = sourcePath.trim()
    if (trimmed.isEmpty()) {
        throw PatchException("Custom NTP wallpaper path must not be blank")
    }
    val target = File(trimmed)
    if (target.isDirectory) {
        val files = target.listFiles { f ->
            f.isFile && f.extension.equals("png", ignoreCase = true)
        }?.sortedBy { it.name }.orEmpty()
        if (files.isEmpty()) {
            throw PatchException("Custom NTP wallpaper directory contains no PNG files: ${target.absolutePath}")
        }
        return files
    }
    if (trimmed.contains(",") || trimmed.contains(";")) {
        val files = trimmed.split(',', ';')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { File(it) }
        if (files.isEmpty()) {
            throw PatchException("Custom NTP wallpaper file list is empty")
        }
        return files
    }
    return listOf(target)
}

internal fun readPngDimensions(file: File): WallpaperDimensions? =
    runCatching {
        DataInputStream(FileInputStream(file).buffered()).use { input ->
            val signature = ByteArray(8)
            input.readFully(signature)
            if (!signature.contentEquals(PNG_SIGNATURE)) return null

            val headerLength = input.readInt()
            val headerType = ByteArray(4)
            input.readFully(headerType)
            if (headerLength != 13 || !headerType.contentEquals(IHDR_CHUNK)) return null

            val width = input.readInt()
            val height = input.readInt()
            if (width <= 0 || height <= 0) return null

            WallpaperDimensions(width, height)
        }
    }.getOrNull()

internal fun installWallpaperResource(resourceDirectory: File, sourceFiles: List<File>): Int {
    val drawableDirectory = resourceDirectory.resolve("drawable-nodpi").apply(File::mkdirs)
    // Clean any previous custom wallpaper drawables to avoid orphan indexed files
    drawableDirectory.listFiles { file ->
        file.name.startsWith(NTP_WALLPAPER_PREFIX) || file.name.startsWith(NTP_WALLPAPER_RESOURCE_NAME)
    }?.forEach { it.delete() }

    sourceFiles.forEachIndexed { index, file ->
        file.copyTo(
            target = drawableDirectory.resolve("ntp_wallpaper_$index.png"),
            overwrite = true,
        )
    }
    if (sourceFiles.isNotEmpty()) {
        sourceFiles.first().copyTo(
            target = drawableDirectory.resolve("$NTP_WALLPAPER_RESOURCE_NAME.png"),
            overwrite = true,
        )
    }
    return sourceFiles.size
}

internal fun installWallpaperResource(resourceDirectory: File, sourceFile: File): Int =
    installWallpaperResource(resourceDirectory, listOf(sourceFile))

private val PNG_SIGNATURE = byteArrayOf(
    0x89.toByte(),
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
)
private val IHDR_CHUNK = byteArrayOf(0x49, 0x48, 0x44, 0x52)

private fun customNtpWallpaperCompatibilities() = listOf(
    Compatibility(
        name = "Brave Browser",
        packageName = "com.brave.browser",
        apkFileType = ApkFileType.APKM,
        appIconColor = 0xFF4500,
        targets = listOf(AppTarget(version = null, isExperimental = true)),
    ),
    Compatibility(
        name = "Brave Beta",
        packageName = "com.brave.browser_beta",
        apkFileType = ApkFileType.APKM,
        appIconColor = 0xFF4500,
        targets = listOf(AppTarget(version = null, isExperimental = true)),
    ),
    Compatibility(
        name = "Brave Nightly",
        packageName = "com.brave.browser_nightly",
        apkFileType = ApkFileType.APKM,
        appIconColor = 0xFF4500,
        targets = listOf(AppTarget(version = null, isExperimental = true)),
    ),
)

// Options live on the public patch; this dependency only materializes the PNGs.
private val customNtpWallpaperResourcePatch: ResourcePatch = resourcePatch(
    name = "Custom NTP wallpaper resources",
    description = "Installs the patch-time wallpaper PNGs as Brave drawables.",
    default = false,
) {
    compatibleWith(*customNtpWallpaperCompatibilities().toTypedArray())
    execute {
        val sourcePath = customNtpWallpaperPatch.options["customWallpaper"]?.value as? String
        val files = resolveWallpaperFiles(sourcePath.orEmpty())
        validateWallpaperFiles(files)
        installWallpaperResource(get("res"), files)
    }
}

/**
 * Alpha / experimental: forces Brave NTP to the supplied PNGs via the Java
 * ambient catalog (drawable resource id) with runtime random rotation. Default off.
 * Ambiguous targets fail closed.
 */
@Suppress("unused")
val customNtpWallpaperPatch: BytecodePatch = bytecodePatch(
    name = "Custom NTP wallpaper",
    description = "Alpha experimental version-unpinned patch (issue #13): forces the Brave " +
        "new-tab background to custom PNGs chosen at patch time with runtime rotation. " +
        "Rewrites the Java ambient wallpaper catalog (BackgroundImage drawable resource id) " +
        "and makes wallpaper callbacks use it instead of native branded/URL images. " +
        "IMPORTANT: crop the images to your current screen resolution first, then select " +
        "that file or directory in the patch options. Brave's New tab page settings only toggle " +
        "\"Show background images\". Default off.",
    default = false,
) {
    dependsOn(customNtpWallpaperResourcePatch)
    extendWith("extensions/extension.mpe")
    compatibleWith(*customNtpWallpaperCompatibilities().toTypedArray())

    val customWallpaperPath by stringOption(
        key = "customWallpaper",
        title = "Custom NTP wallpaper",
        description = "Path to a PNG file, directory of PNGs, or comma-separated list of PNG files " +
            "used as Brave new-tab background(s). 480-8192 px on each side, maximum 8 MiB per file.",
        required = true,
        validator = { value -> !value.isNullOrBlank() },
    )

    execute {
        val sourcePath = customWallpaperPath?.trim().orEmpty()
        val files = resolveWallpaperFiles(sourcePath)
        validateWallpaperFiles(files)
        val wallpaperCount = files.size

        val accessorMethod = AmbientCatalogAccessorFingerprint.methodOrNull
            ?: error("ambient wallpaper catalog accessor not found")
        val catalogClass = AmbientCatalogAccessorFingerprint.originalClassDef.type
        val catalogMethod = AmbientCatalogAccessorFingerprint.originalMethod?.name
            ?: error("ambient wallpaper catalog accessor name missing")
        val resourceIdField = backgroundImageResourceIdField(
            AmbientCatalogAccessorFingerprint.originalClassDef,
        )

        accessorMethod.apply {
            removeInstructions(0, implementation!!.instructions.count())
            addInstructions(0, forceAmbientCatalogAccessorSmali(resourceIdField, wallpaperCount))
        }

        var forcedCallbacks = 0
        classDefForEach { classDef ->
            classDef.methods.forEach { method ->
                if (method.returnType != "V" ||
                    method.parameterTypes.toList() != listOf("Ljava/lang/Object;") ||
                    method.implementation == null
                ) {
                    return@forEach
                }
                val callsCatalog = method.implementation!!.instructions.any { ins ->
                    val ref = (ins as? ReferenceInstruction)?.reference as? MethodReference
                    ref != null &&
                        ref.definingClass == catalogClass &&
                        ref.name == catalogMethod &&
                        ref.parameterTypes.isEmpty() &&
                        ref.returnType == BACKGROUND_IMAGE_MODEL
                }
                if (!callsCatalog) return@forEach

                mutableClassDefBy(classDef).methods
                    .first { it.name == method.name && it.parameterTypes == method.parameterTypes }
                    .addInstructions(0, forceUseAmbientCatalogSmali(catalogClass, catalogMethod))
                forcedCallbacks++
            }
        }
        if (forcedCallbacks == 0) {
            error("no wallpaper callbacks call the ambient catalog accessor")
        }

        // Secondary: keep JNI factories consistent if some path still reads them.
        // Resolve package matching actual APK (com.brave.browser, com.brave.browser_beta, or com.brave.browser_nightly)
        var detectedPkg = packageMetadata.packageName?.takeIf { it.isNotBlank() }
        if (detectedPkg == null) {
            classDefForEach { classDef ->
                if (detectedPkg != null) return@classDefForEach
                val type = classDef.type
                when {
                    type.startsWith("Lcom/brave/browser_nightly/") -> detectedPkg = "com.brave.browser_nightly"
                    type.startsWith("Lcom/brave/browser_beta/") -> detectedPkg = "com.brave.browser_beta"
                    type.startsWith("Lcom/brave/browser/") -> detectedPkg = "com.brave.browser"
                }
            }
        }
        val pkg = detectedPkg ?: "com.brave.browser"

        CreateWallpaperFingerprint.methodOrNull?.addInstructions(
            0,
            forceCreateWallpaperParamsSmali(pkg, wallpaperCount),
        )
        CreateBrandedWallpaperFingerprint.methodOrNull?.addInstructions(
            0,
            forceCreateBrandedWallpaperParamsSmali(pkg, wallpaperCount),
        )
    }
}
