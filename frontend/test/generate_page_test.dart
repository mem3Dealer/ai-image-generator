import 'package:ai_image_generator/core/api_client.dart';
import 'package:ai_image_generator/core/generation_options.dart';
import 'package:ai_image_generator/core/subscription_status.dart';
import 'package:ai_image_generator/features/generate/generate_bloc.dart';
import 'package:ai_image_generator/features/generate/generate_page.dart';
import 'package:ai_image_generator/features/generate/generate_state.dart';
import 'package:ai_image_generator/features/subscription/subscription_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/temporary_store.dart';

const GenerationOptions _premiumOptions = GenerationOptions(
  style: animeStyle,
  aspectRatio: portraitAspectRatio,
  quality: hdQuality,
);

void main() {
  testWidgets('a free user opening Anime does not start generation', (WidgetTester tester) async {
    final TemporaryStore temporary = await _openStore(tester);
    final ApiClient apiClient = ApiClient(
      baseUrl: apiBaseUrl,
      userId: '6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f',
      client: MockClient((http.Request request) async {
        fail('generation must not start');
      }),
    );
    final SubscriptionBloc subscriptionBloc = SubscriptionBloc(
      apiClient: apiClient,
      localStore: temporary.store,
      initialStatus: SubscriptionStatus.free,
    );
    final GenerateBloc generateBloc = GenerateBloc(
      apiClient: apiClient,
      localStore: temporary.store,
    );
    addTearDown(subscriptionBloc.close);
    addTearDown(generateBloc.close);
    addTearDown(apiClient.close);
    await _pumpPage(tester, subscriptionBloc, generateBloc);
    await tester.tap(find.text('Anime · Premium'));
    await _showFrame(tester);
    expect(find.text('Continue with Premium'), findsOneWidget);
    expect(generateBloc.state, isA<GenerateIdle>());
    expect(_chip(tester, 'Anime · Premium').selected, isFalse);
  });

  testWidgets('an empty prompt shows an input error card', (WidgetTester tester) async {
    final TemporaryStore temporary = await _openStore(tester);
    final ApiClient apiClient = ApiClient(
      baseUrl: apiBaseUrl,
      userId: '6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f',
      client: MockClient((http.Request request) async {
        fail('generation must not start');
      }),
    );
    final SubscriptionBloc subscriptionBloc = SubscriptionBloc(
      apiClient: apiClient,
      localStore: temporary.store,
      initialStatus: SubscriptionStatus.free,
    );
    final GenerateBloc generateBloc = GenerateBloc(
      apiClient: apiClient,
      localStore: temporary.store,
    );
    addTearDown(subscriptionBloc.close);
    addTearDown(generateBloc.close);
    addTearDown(apiClient.close);
    await _pumpPage(tester, subscriptionBloc, generateBloc);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(find.text('Check your input'), findsOneWidget);
    expect(find.text('Prompt is required'), findsOneWidget);
    expect(generateBloc.state, isA<GenerateFailure>());
  });

  testWidgets('Cinematic stays in place when selected on a narrow screen', (
    WidgetTester tester,
  ) async {
    final TemporaryStore temporary = await _openStore(tester);
    final ApiClient apiClient = ApiClient(
      baseUrl: apiBaseUrl,
      userId: '6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f',
      client: MockClient((http.Request request) async {
        return http.Response('{"status":"premium"}', 200);
      }),
    );
    final SubscriptionBloc subscriptionBloc = SubscriptionBloc(
      apiClient: apiClient,
      localStore: temporary.store,
      initialStatus: SubscriptionStatus.premium,
    );
    final GenerateBloc generateBloc = GenerateBloc(
      apiClient: apiClient,
      localStore: temporary.store,
    );
    addTearDown(subscriptionBloc.close);
    addTearDown(generateBloc.close);
    addTearDown(apiClient.close);
    await _pumpPage(
      tester,
      subscriptionBloc,
      generateBloc,
      size: const Size(320, 700),
    );
    final Finder cinematic = find.widgetWithText(ChoiceChip, 'Cinematic · Premium');
    final Offset before = tester.getTopLeft(cinematic);
    final double width = tester.getSize(cinematic).width;
    expect(tester.getSize(find.widgetWithText(ChoiceChip, 'Photorealistic')).width, width);
    await tester.tap(cinematic);
    await tester.pump();
    expect(tester.getTopLeft(cinematic), before);
    expect(tester.getSize(cinematic).width, width);
    expect(_chip(tester, 'Cinematic · Premium').selected, isTrue);
  });

  testWidgets('premium purchase after a rejection keeps the rejected options', (
    WidgetTester tester,
  ) async {
    final TemporaryStore temporary = await _openStore(tester, createUser: true);
    final ApiClient apiClient = ApiClient(
      baseUrl: apiBaseUrl,
      userId: '6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f',
      client: MockClient((http.Request request) async {
        if (request.url.path == '/api/subscription/purchase') {
          return http.Response('{"status":"premium"}', 200);
        }
        return http.Response(
          '{"error":{"code":"PREMIUM_REQUIRED","message":"This option requires a Premium subscription"}}',
          403,
        );
      }),
    );
    final SubscriptionBloc subscriptionBloc = SubscriptionBloc(
      apiClient: apiClient,
      localStore: temporary.store,
      initialStatus: SubscriptionStatus.free,
    );
    final GenerateBloc generateBloc = GenerateBloc(
      apiClient: apiClient,
      localStore: temporary.store,
    );
    addTearDown(subscriptionBloc.close);
    addTearDown(generateBloc.close);
    addTearDown(apiClient.close);
    await _pumpPage(tester, subscriptionBloc, generateBloc);
    await generateBloc.generate(prompt: 'A city', options: _premiumOptions);
    await tester.pump();
    await _flushIo(tester);
    await _showFrame(tester);
    await tester.tap(find.text('Continue with Premium'));
    await tester.pump();
    await _flushIo(tester);
    await _showFrame(tester);
    expect(_chip(tester, 'Anime · Premium').selected, isTrue);
    expect(_chip(tester, '2:3').selected, isTrue);
    expect(_chip(tester, 'HD · Premium').selected, isTrue);
    expect(subscriptionBloc.state.status, SubscriptionStatus.premium);
  });
}

Future<TemporaryStore> _openStore(WidgetTester tester, {bool createUser = false}) async {
  final TemporaryStore temporary = (await tester.runAsync(() async {
    final TemporaryStore opened = await openTemporaryStore();
    if (createUser) {
      await opened.store.ensureUserId();
    }
    return opened;
  }))!;
  addTearDown(() async {
    await temporary.delete();
  });
  return temporary;
}

Future<void> _flushIo(WidgetTester tester) {
  return tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
}

Future<void> _pumpPage(
  WidgetTester tester,
  SubscriptionBloc subscriptionBloc,
  GenerateBloc generateBloc, {
  Size size = const Size(800, 1400),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return tester.pumpWidget(
    MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider<SubscriptionBloc>.value(value: subscriptionBloc),
          BlocProvider<GenerateBloc>.value(value: generateBloc),
        ],
        child: const Scaffold(body: GeneratePage()),
      ),
    ),
  );
}

Future<void> _showFrame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

ChoiceChip _chip(WidgetTester tester, String label) {
  return tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));
}
