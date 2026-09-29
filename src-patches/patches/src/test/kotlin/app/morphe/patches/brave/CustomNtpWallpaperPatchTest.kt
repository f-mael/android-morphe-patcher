package app.morphe.patches.brave

import app.morphe.patcher.patch.PatchException
import java.io.DataOutputStream
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CustomNtpWallpaperPatchTest {
    @Test
    fun `valid landscape PNG is accepted`() {
        val wallpaper = createPngHeaderFile(width = 1920, height = 1080)

        assertEquals(WallpaperDimensions(1920, 1080), validateWallpaperFile(wallpaper))
    }

    @Test
    fun `undersized PNG is rejected`() {
        val wallpaper = createPngHeaderFile(width = 320, height = 240)

        assertFailsWith<Exception> {
            validateWallpaperFile(wallpaper)
        }
    }

    @Test
    fun `non-PNG is rejected`() {
        val file = kotlin.io.path.createTempFile("wallpaper", ".png").toFile()
        file.writeBytes(byteArrayOf(1, 2, 3, 4))

        assertFailsWith<Exception> {
            validateWallpaperFile(file)
        }
    }

    @Test
    fun `multiple PNG files resolved from directory`() {
        val dir = createTempDirectory("wallpaper-dir").toFile()
        val w1 = createPngHeaderFile(dir.resolve("wallpaper_a.png"), 1920, 1080)
        val w2 = createPngHeaderFile(dir.resolve("wallpaper_b.png"), 2560, 1440)
        val w3 = createPngHeaderFile(dir.resolve("wallpaper_c.png"), 1080, 1920)

        val resolved = resolveWallpaperFiles(dir.absolutePath)
        assertEquals(3, resolved.size)
        assertEquals(listOf(w1.name, w2.name, w3.name), resolved.map { it.name })

        val dimensions = validateWallpaperFiles(resolved)
        assertEquals(3, dimensions.size)
        assertEquals(WallpaperDimensions(1920, 1080), dimensions[0])
        assertEquals(WallpaperDimensions(2560, 1440), dimensions[1])
        assertEquals(WallpaperDimensions(1080, 1920), dimensions[2])
    }

    @Test
    fun `multiple PNG files resolved from list`() {
        val dir = createTempDirectory("wallpaper-list-dir").toFile()
        val w1 = createPngHeaderFile(dir.resolve("w1.png"), 1920, 1080)
        val w2 = createPngHeaderFile(dir.resolve("w2.png"), 1920, 1080)

        val resolved = resolveWallpaperFiles("${w1.absolutePath}, ${w2.absolutePath}")
        assertEquals(2, resolved.size)
        assertEquals(listOf(w1.absolutePath, w2.absolutePath), resolved.map { it.absolutePath })
    }

    @Test
    fun `empty directory or blank path throws PatchException`() {
        val emptyDir = createTempDirectory("empty-wallpaper-dir").toFile()
        assertFailsWith<PatchException> {
            resolveWallpaperFiles(emptyDir.absolutePath)
        }

        assertFailsWith<PatchException> {
            resolveWallpaperFiles("   ")
        }
    }

    @Test
    fun `resource install writes indexed nodpi drawables`() {
        val resources = createTempDirectory("wallpaper-resources").toFile()
        val dir = createTempDirectory("sources-dir").toFile()
        val source1 = createPngHeaderFile(dir.resolve("src1.png"), width = 1920, height = 1080)
        val source2 = createPngHeaderFile(dir.resolve("src2.png"), width = 2560, height = 1440)
        val source3 = createPngHeaderFile(dir.resolve("src3.png"), width = 1080, height = 1920)

        val count = installWallpaperResource(resources, listOf(source1, source2, source3))
        assertEquals(3, count)

        val installed0 = resources.resolve("drawable-nodpi/ntp_wallpaper_0.png")
        val installed1 = resources.resolve("drawable-nodpi/ntp_wallpaper_1.png")
        val installed2 = resources.resolve("drawable-nodpi/ntp_wallpaper_2.png")
        val legacy = resources.resolve("drawable-nodpi/$NTP_WALLPAPER_RESOURCE_NAME.png")

        assertTrue(installed0.isFile)
        assertTrue(installed1.isFile)
        assertTrue(installed2.isFile)
        assertTrue(legacy.isFile)

        assertEquals(source1.readBytes().toList(), installed0.readBytes().toList())
        assertEquals(source2.readBytes().toList(), installed1.readBytes().toList())
        assertEquals(source3.readBytes().toList(), installed2.readBytes().toList())
        assertEquals(source1.readBytes().toList(), legacy.readBytes().toList())
    }

    @Test
    fun `factory prologues generate random index and build dynamic uri`() {
        val pkg = "vip.dh6k.brave.origin.nightly"
        val create = forceCreateWallpaperParamsSmali(pkg, 3)

        assertTrue("new-instance p0, Ljava/util/Random;" in create)
        assertTrue("invoke-virtual {p0, p1}, Ljava/util/Random;->nextInt(I)I" in create)
        assertTrue("const-string p1, \"ntp_wallpaper_\"" in create)
        assertTrue("const-string p1, \"android.resource://$pkg/drawable/\"" in create)
        assertTrue("const-string p2, \"Custom\"" in create)

        // Verify that only p0, p1, p2 are touched
        assertFalse(Regex("""\bp[3-9]\b""").containsMatchIn(create))
        assertFalse(Regex("""\bv[0-9]+\b""").containsMatchIn(create))
    }

    @Test
    fun `branded prologue generates random index and does not clobber int or boolean params`() {
        val pkg = "com.brave.browser_nightly"
        val smali = forceCreateBrandedWallpaperParamsSmali(pkg, 3)

        assertTrue("new-instance p0, Ljava/util/Random;" in smali)
        assertTrue("invoke-virtual {p0, p3}, Ljava/util/Random;->nextInt(I)I" in smali)
        assertTrue("const-string p3, \"android.resource://$pkg/drawable/\"" in smali)

        // createBrandedWallpaper is static with 10 params; v0/v1 alias p0/p1.
        // Touching v1 put a String into the int slot and failed ART verification.
        assertFalse(Regex("""\bv[0-9]+\b""").containsMatchIn(smali))
        assertFalse(Regex("""\bp[12589]\b""").containsMatchIn(smali))
    }

    @Test
    fun `ambient catalog factory calls helper and only uses v0 v1`() {
        val field =
            "Lorg/chromium/chrome/browser/ntp_background_images/model/BackgroundImage;->a:I"

        // Single wallpaper mode
        val smaliSingle = forceAmbientCatalogAccessorSmali(field, 1)
        assertTrue("invoke-static {}, $NTP_WALLPAPER_HELPER->drawableId()I" in smaliSingle)
        assertTrue("iput v0, v1, $field" in smaliSingle)
        assertTrue("return-object v1" in smaliSingle)
        assertFalse(Regex("""\bv[3-9]\d*\b""").containsMatchIn(smaliSingle))

        // Multiple wallpaper mode
        val smaliMulti = forceAmbientCatalogAccessorSmali(field, 5)
        assertTrue("invoke-static {v0}, $NTP_WALLPAPER_HELPER->drawableId(I)I" in smaliMulti)
        assertTrue("iput v0, v1, $field" in smaliMulti)
        assertTrue("return-object v1" in smaliMulti)
        assertFalse(Regex("""\bv[3-9]\d*\b""").containsMatchIn(smaliMulti))

        // Neither should use R$drawable or getIdentifier directly
        assertFalse("R\$drawable" in smaliMulti)
        assertFalse("getIdentifier" in smaliMulti)
    }

    @Test
    fun `callback force replaces native wallpaper object with catalog result`() {
        val smali = forceUseAmbientCatalogSmali("Lt9i;", "a")

        assertTrue("invoke-static {}, Lt9i;->a()" in smali)
        assertTrue(BACKGROUND_IMAGE_MODEL in smali)
        assertTrue("move-result-object p1" in smali)
    }

    private fun createPngHeaderFile(width: Int, height: Int): File {
        val file = kotlin.io.path.createTempFile("ntp-wallpaper", ".png").toFile()
        return createPngHeaderFile(file, width, height)
    }

    private fun createPngHeaderFile(file: File, width: Int, height: Int): File {
        DataOutputStream(file.outputStream()).use { output ->
            output.write(
                byteArrayOf(
                    0x89.toByte(),
                    0x50,
                    0x4E,
                    0x47,
                    0x0D,
                    0x0A,
                    0x1A,
                    0x0A,
                ),
            )
            output.writeInt(13)
            output.write(byteArrayOf(0x49, 0x48, 0x44, 0x52))
            output.writeInt(width)
            output.writeInt(height)
            output.write(ByteArray(5))
        }
        return file
    }
}
