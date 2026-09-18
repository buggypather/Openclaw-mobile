# OpenClaw Mobile release rules. R8 may aggressively shrink Bouncy Castle; keep
# only the Ed25519 classes we instantiate directly and OkHttp's public model.
-keep class org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters { *; }
-keep class org.bouncycastle.crypto.params.Ed25519PublicKeyParameters { *; }
-keep class org.bouncycastle.crypto.signers.Ed25519Signer { *; }
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.jsse.**
-dontwarn org.openjsse.**
