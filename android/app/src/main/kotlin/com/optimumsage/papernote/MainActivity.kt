package com.optimumsage.papernote

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth's
// androidx.biometric BiometricPrompt, which needs a FragmentActivity host.
class MainActivity : FlutterFragmentActivity()
