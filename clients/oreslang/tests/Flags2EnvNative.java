package dev.oreslang.runtime;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;

/** Minimal Java/Graal host-side smoke for Oreslang JNI C bridge. */
public final class Flags2EnvNative {
    static {
        System.loadLibrary("flags2env_oreslang_jni");
    }
    private static native byte[] parseFileBytes(byte[] config, byte[] argv);

    public static void main(String[] args) {
        if (args.length != 1) throw new IllegalArgumentException("config path required");
        byte[] result = parseFileBytes(
                args[0].getBytes(StandardCharsets.UTF_8),
                "[\"probe\",\"--port\",\"4012\"]".getBytes(StandardCharsets.UTF_8));
        if (result == null) throw new AssertionError("JNI failed");
        String value = new String(result, StandardCharsets.UTF_8);
        if (!value.contains("4012")) throw new AssertionError(value);
        if (parseFileBytes(new byte[] {0}, "[\"probe\"]".getBytes(StandardCharsets.UTF_8)) != null)
            throw new AssertionError("embedded-NUL config must be refused");
        System.out.println("Oreslang JNI flags2env smoke passed");
    }
}
