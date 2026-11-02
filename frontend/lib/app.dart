import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/active_generation.dart';
import 'core/api_client.dart';
import 'core/local_store.dart';
import 'core/subscription_status.dart';
import 'features/generate/generate_bloc.dart';
import 'features/generate/generate_page.dart';
import 'features/history/history_bloc.dart';
import 'features/history/history_page.dart';
import 'features/settings/settings_page.dart';
import 'features/subscription/subscription_bloc.dart';

class ImageGeneratorApp extends StatefulWidget {
  const ImageGeneratorApp({
    required this.localStore,
    required this.apiClient,
    required this.userId,
    required this.initialSubscription,
    required this.activeGeneration,
    super.key,
  });

  final LocalStore localStore;
  final ApiClient apiClient;
  final String userId;
  final SubscriptionStatus initialSubscription;
  final ActiveGeneration? activeGeneration;

  @override
  State<ImageGeneratorApp> createState() => _ImageGeneratorAppState();
}

class _ImageGeneratorAppState extends State<ImageGeneratorApp> {
  late final SubscriptionBloc _subscriptionBloc;
  late final GenerateBloc _generateBloc;
  late final HistoryBloc _historyBloc;

  @override
  void initState() {
    super.initState();
    _subscriptionBloc = SubscriptionBloc(
      apiClient: widget.apiClient,
      localStore: widget.localStore,
      initialStatus: widget.initialSubscription,
    );
    _generateBloc = GenerateBloc(
      apiClient: widget.apiClient,
      localStore: widget.localStore,
      activeGeneration: widget.activeGeneration,
    );
    _historyBloc = HistoryBloc(localStore: widget.localStore);
    _historyBloc.load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subscriptionBloc.refresh();
    });
  }

  @override
  void dispose() {
    _subscriptionBloc.close();
    _generateBloc.close();
    _historyBloc.close();
    widget.apiClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<SubscriptionBloc>.value(value: _subscriptionBloc),
        BlocProvider<GenerateBloc>.value(value: _generateBloc),
        BlocProvider<HistoryBloc>.value(value: _historyBloc),
      ],
      child: MaterialApp(
        title: 'AI Image Generator',
        theme: _theme(),
        home: _Shell(userId: widget.userId),
      ),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell({required this.userId});

  final String userId;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: <Widget>[
            const GeneratePage(),
            const HistoryPage(),
            SettingsPage(userId: widget.userId),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _selectTab,
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'Generate',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            selectedIcon: Icon(Icons.photo_library),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  void _selectTab(int index) {
    setState(() => _index = index);
    if (index == 1) {
      context.read<HistoryBloc>().load();
    }
  }
}

ThemeData _theme() {
  const Color paper = Color(0xFFF3F0E8);
  const Color ink = Color(0xFF1C1917);
  const Color accent = Color(0xFF0F6E6B);
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: accent,
    surface: const Color(0xFFFFFCF8),
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: paper,
    useMaterial3: true,
    textTheme: ThemeData.light().textTheme.apply(bodyColor: ink, displayColor: ink),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFFFFFCF8),
      indicatorColor: accent.withValues(alpha: 0.16),
    ),
  );
}
