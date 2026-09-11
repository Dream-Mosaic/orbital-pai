import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import 'tokens.dart';

/// The full-screen "you are signed out" state — a whole screen, not a drawer,
/// because there is nothing underneath it to draw over: no conversation, no
/// nav, no panels. Nothing else in the app is reachable without a token.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key, required this.controller});

  final AuthController controller;

  static const _wordmarkSize = 26.0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        backgroundColor: M.bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'HENRY',
                    style: TextStyle(
                      fontFamily: kDisplayFamily,
                      fontSize: _wordmarkSize,
                      color: M.ink,
                      fontWeight: FontWeight.w600,
                      fontVariations: MType.wght(650),
                      letterSpacing: MType.track(_wordmarkSize, 0.42),
                      shadows: MType.wordmark,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Sign in to talk to Henry.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: kBodyFamily,
                      fontSize: 15,
                      color: M.inkDim,
                    ),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('login-screen-sign-in'),
                      onPressed: controller.signIn,
                      style: FilledButton.styleFrom(
                        backgroundColor: M.henry,
                        foregroundColor: M.bg,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        textStyle: const TextStyle(
                          fontFamily: kBodyFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Sign in'),
                    ),
                  ),
                  if (controller.error case final error?) ...[
                    const SizedBox(height: 18),
                    Text(
                      error,
                      key: const Key('login-screen-error'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: kBodyFamily,
                        fontSize: 13,
                        color: Color(0xFFEF4444),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
