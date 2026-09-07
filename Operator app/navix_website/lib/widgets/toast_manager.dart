import 'dart:async';
import 'package:flutter/material.dart';
import 'package:navix_app/widgets/hud_animations.dart';

enum ToastType { info, warning, critical }

class HudToast {
  final String id;
  final String message;
  final ToastType type;
  final DateTime timestamp;

  HudToast({
    required this.id,
    required this.message,
    required this.type,
    required this.timestamp,
  });
}

class ToastManager {
  static final ValueNotifier<List<HudToast>> toasts = ValueNotifier<List<HudToast>>([]);

  static void show(String message, {ToastType type = ToastType.info}) {
    final newToast = HudToast(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      message: message,
      type: type,
      timestamp: DateTime.now(),
    );
    
    // Cap maximum concurrent toasts to 5 to prevent visual overflow
    final currentList = List<HudToast>.from(toasts.value);
    if (currentList.length >= 5) {
      currentList.removeAt(0);
    }
    
    toasts.value = List.from(currentList)..add(newToast);

    // Auto dismiss after 5 seconds
    Timer(const Duration(seconds: 5), () {
      dismiss(newToast.id);
    });
  }

  static void dismiss(String id) {
    toasts.value = List.from(toasts.value)..removeWhere((t) => t.id == id);
  }
}

class ToastOverlayStack extends StatelessWidget {
  const ToastOverlayStack({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 80,
      right: 24,
      child: ValueListenableBuilder<List<HudToast>>(
        valueListenable: ToastManager.toasts,
        builder: (context, toastList, child) {
          if (toastList.isEmpty) return const SizedBox.shrink();
          
          return SizedBox(
            width: 320,
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: toastList.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final toast = toastList[index];
                return _buildToastCard(toast);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildToastCard(HudToast toast) {
    Color neonColor;
    String prefix;
    switch (toast.type) {
      case ToastType.critical:
        neonColor = const Color(0xFFFF2E8A);
        prefix = "ALERT";
        break;
      case ToastType.warning:
        neonColor = const Color(0xFFFFB02E);
        prefix = "WARN";
        break;
      case ToastType.info:
        neonColor = const Color(0xFF0DFFC8);
        prefix = "SYS";
        break;
    }

    return GlitchWrapper(
      value: toast.id,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1017).withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: neonColor.withValues(alpha: 0.5), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: neonColor.withValues(alpha: 0.1),
              blurRadius: 10,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: neonColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: neonColor, width: 0.5),
              ),
              child: Text(
                prefix,
                style: TextStyle(
                  color: neonColor,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                toast.message.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => ToastManager.dismiss(toast.id),
              child: const Icon(
                Icons.close,
                color: Colors.white70,
                size: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
