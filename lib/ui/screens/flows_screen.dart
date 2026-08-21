import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/desktop_automation/providers/flow_builder_provider.dart';
import 'flow_builder_screen.dart';
import 'flow_list_panel.dart';

/// Root screen for the Flows tab. Shows either the flow list
/// or the flow builder, depending on state.
class FlowsScreen extends StatefulWidget {
  const FlowsScreen({super.key});

  @override
  State<FlowsScreen> createState() => _FlowsScreenState();
}

class _FlowsScreenState extends State<FlowsScreen> {
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      // Load flows on first build
      final provider = Provider.of<FlowBuilderProvider>(
        context,
        listen: false,
      );
      provider.loadFlows();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<FlowBuilderProvider>(
      builder: (context, provider, _) {
        if (provider.isBuilderOpen && provider.currentFlow != null) {
          return const FlowBuilderScreen();
        }
        return const FlowListPanel();
      },
    );
  }
}
