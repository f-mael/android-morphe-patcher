package app.morphe.extension.brave;

import android.content.Context;
import android.content.res.Resources;
import java.util.Random;

/**
 * Resolves the Morphe-installed NTP wallpaper drawable at runtime.
 * Lives in the extension so bytecode sites only need a 2-register
 * invoke-static — tight Chromium factories (e.g. 3-register ambient
 * catalog accessors) cannot host getIdentifier's 4-arg invoke.
 * Supports random rotation across multiple indexed wallpapers (ntp_wallpaper_0, ntp_wallpaper_1, ...).
 */
public final class NtpWallpaperIds {
    private static final String LEGACY_DRAWABLE = "morphe_custom_ntp_wallpaper";
    private static final String PREFIX = "ntp_wallpaper_";
    private static final Random RANDOM = new Random();
    private static int cachedWallpaperCount = -1;

    private NtpWallpaperIds() {}

    public static int drawableId() {
        return drawableId(-1);
    }

    public static int drawableId(int totalCount) {
        try {
            Context app = currentApplication();
            if (app == null) return 0;
            Resources res = app.getResources();
            if (res == null) return 0;
            String pkg = app.getPackageName();

            int count = totalCount;
            if (count <= 0) {
                count = getOrCountWallpapers(res, pkg);
            }

            if (count <= 1) {
                int id = res.getIdentifier(PREFIX + "0", "drawable", pkg);
                if (id != 0) return id;
                return res.getIdentifier(LEGACY_DRAWABLE, "drawable", pkg);
            }

            int randomIndex = RANDOM.nextInt(count);
            int id = res.getIdentifier(PREFIX + randomIndex, "drawable", pkg);
            if (id != 0) return id;

            // Fallback to index 0 or legacy if specific index fails
            int fallback = res.getIdentifier(PREFIX + "0", "drawable", pkg);
            if (fallback != 0) return fallback;
            return res.getIdentifier(LEGACY_DRAWABLE, "drawable", pkg);
        } catch (Throwable t) {
            return 0;
        }
    }

    private static int getOrCountWallpapers(Resources res, String pkg) {
        if (cachedWallpaperCount > 0) {
            return cachedWallpaperCount;
        }
        int count = 0;
        while (res.getIdentifier(PREFIX + count, "drawable", pkg) != 0) {
            count++;
        }
        if (count == 0) {
            if (res.getIdentifier(LEGACY_DRAWABLE, "drawable", pkg) != 0) {
                count = 1;
            }
        }
        cachedWallpaperCount = Math.max(count, 1);
        return cachedWallpaperCount;
    }

    /** Hidden API; resolve reflectively so this class compiles against public SDK. */
    private static Context currentApplication() {
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Object app = at.getDeclaredMethod("currentApplication").invoke(null);
            return (Context) app;
        } catch (Throwable t) {
            return null;
        }
    }
}
