import 'package:flutter/material.dart';
import '../utils/math_symbols.dart';

class MathSymbolsPanel extends StatefulWidget {
  final void Function(String symbol) onSymbolSelected;
  final VoidCallback onClose;

  const MathSymbolsPanel({
    super.key,
    required this.onSymbolSelected,
    required this.onClose,
  });

  @override
  State<MathSymbolsPanel> createState() => _MathSymbolsPanelState();
}

class _MathSymbolsPanelState extends State<MathSymbolsPanel> {
  String _activeTab = 'Basic';

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 340,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF1a1f3a),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 32),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Text(
                  'Symbols',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: widget.onClose,
                  child: Icon(Icons.close, size: 18, color: Colors.white.withValues(alpha: 0.4)),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Tabs
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: MathSymbols.categories.keys.map((tab) {
                  final isActive = _activeTab == tab;
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: GestureDetector(
                      onTap: () => setState(() => _activeTab = tab),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isActive
                              ? const Color(0xFF4361ee).withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          tab,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isActive
                                ? const Color(0xFF4361ee)
                                : Colors.white.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            const SizedBox(height: 8),

            // Symbol grid
            Wrap(
              spacing: 2,
              runSpacing: 2,
              children: (MathSymbols.categories[_activeTab] ?? []).map((sym) {
                return GestureDetector(
                  onTap: () => widget.onSymbolSelected(sym),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Center(
                      child: Text(
                        sym,
                        style: TextStyle(
                          fontSize: sym.length > 2 ? 11 : 16,
                          color: Colors.white.withValues(alpha: 0.9),
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
