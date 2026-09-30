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

    private static final String[] CANDIDATE_PACKAGES = new String[] {
        "com.brave.browser",
        "com.brave.browser_beta",
        "com.brave.browser_nightly",
        "org.chromium.chrome"
    };

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
                int id = findDrawableId(res, PREFIX + "0", pkg);
                if (id != 0) return id;
                return findDrawableId(res, LEGACY_DRAWABLE, pkg);
            }

            int randomIndex = RANDOM.nextInt(count);
            int id = findDrawableId(res, PREFIX + randomIndex, pkg);
            if (id != 0) return id;

            // Fallback to index 0 or legacy if specific index fails
            int fallback = findDrawableId(res, PREFIX + "0", pkg);
            if (fallback != 0) return fallback;
            return findDrawableId(res, LEGACY_DRAWABLE, pkg);
        } catch (Throwable t) {
            return 0;
        }
    }

    public static String wallpaperUri() {
        return wallpaperUri(null, -1);
    }

    public static String wallpaperUri(int totalCount) {
        return wallpaperUri(null, totalCount);
    }

    public static String wallpaperUri(String fallbackPkg, int totalCount) {
        Context app = currentApplication();
        String pkg = (app != null) ? app.getPackageName() : fallbackPkg;
        if (pkg == null || pkg.isEmpty()) {
            pkg = "com.brave.browser";
        }
        Resources res = (app != null) ? app.getResources() : null;

        int count = totalCount;
        if (count <= 0 && res != null) {
            count = getOrCountWallpapers(res, pkg);
        }

        int index = 0;
        if (count > 1) {
            index = RANDOM.nextInt(count);
        }
        return "android.resource://" + pkg + "/drawable/ntp_wallpaper_" + index;
    }

    private static int findDrawableId(Resources res, String name, String appPkg) {
        if (res == null) return 0;

        // 1. Try with app.getPackageName()
        if (appPkg != null && !appPkg.isEmpty()) {
            int id = res.getIdentifier(name, "drawable", appPkg);
            if (id != 0) return id;
            try {
                id = res.getIdentifier(appPkg + ":drawable/" + name, null, null);
                if (id != 0) return id;
            } catch (Throwable ignored) {}
        }

        // 2. Try known package variants
        for (String candidate : CANDIDATE_PACKAGES) {
            if (candidate.equals(appPkg)) continue;
            try {
                int id = res.getIdentifier(name, "drawable", candidate);
                if (id != 0) return id;
                id = res.getIdentifier(candidate + ":drawable/" + name, null, null);
                if (id != 0) return id;
            } catch (Throwable ignored) {}
        }

        // 3. Try null package (searches default resource package)
        try {
            int id = res.getIdentifier(name, "drawable", null);
            if (id != 0) return id;
        } catch (Throwable ignored) {}

        return 0;
    }

    private static int getOrCountWallpapers(Resources res, String pkg) {
        if (cachedWallpaperCount > 0) {
            return cachedWallpaperCount;
        }
        int count = 0;
        while (findDrawableId(res, PREFIX + count, pkg) != 0) {
            count++;
        }
        if (count == 0) {
            if (findDrawableId(res, LEGACY_DRAWABLE, pkg) != 0) {
                count = 1;
            }
        }
        cachedWallpaperCount = Math.max(count, 1);
        return cachedWallpaperCount;
    }

    /**
     * Resolve Application Context through multiple fallback mechanisms so that
     * ambient catalog calls always obtain the valid Resources instance.
     */
    private static Context currentApplication() {
        // 1. Chromium ContextUtils (standard in Brave/Chromium runtimes)
        try {
            Class<?> cu = Class.forName("org.chromium.base.ContextUtils");
            Object app = cu.getDeclaredMethod("getApplicationContext").invoke(null);
            if (app instanceof Context) {
                return (Context) app;
            }
        } catch (Throwable ignored) {}

        // 2. ActivityThread.currentApplication()
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Object app = at.getDeclaredMethod("currentApplication").invoke(null);
            if (app instanceof Context) {
                return (Context) app;
            }
        } catch (Throwable ignored) {}

        // 3. ActivityThread.currentActivityThread().getApplication()
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Object cat = at.getDeclaredMethod("currentActivityThread").invoke(null);
            if (cat != null) {
                Object app = at.getDeclaredMethod("getApplication").invoke(cat);
                if (app instanceof Context) {
                    return (Context) app;
                }
            }
        } catch (Throwable ignored) {}

        // 4. AppGlobals.getInitialApplication()
        try {
            Class<?> ag = Class.forName("android.app.AppGlobals");
            Object app = ag.getDeclaredMethod("getInitialApplication").invoke(null);
            if (app instanceof Context) {
                return (Context) app;
            }
        } catch (Throwable ignored) {}

        return null;
    }
}
