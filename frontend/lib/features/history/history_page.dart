import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/generation_options.dart';
import '../../core/history_entry.dart';
import 'history_bloc.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HistoryBloc, HistoryState>(
      builder: (BuildContext context, HistoryState state) {
        if (state.isLoading && state.entries.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state.entries.isEmpty) {
          return const _EmptyHistory();
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          itemCount: state.entries.length + 1,
          separatorBuilder: (BuildContext context, int index) => const SizedBox(height: 12),
          itemBuilder: (BuildContext context, int index) {
            if (index == 0) {
              return Text('History', style: Theme.of(context).textTheme.headlineMedium);
            }
            return _HistoryCard(entry: state.entries[index - 1]);
          },
        );
      },
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.photo_outlined, size: 36, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text('No generations yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Images you generate stay on this device.'),
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _thumbnail(entry),
            const SizedBox(width: 12),
            Expanded(child: _HistoryDetails(entry: entry)),
          ],
        ),
      ),
    );
  }
}

class _HistoryDetails extends StatelessWidget {
  const _HistoryDetails({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final String status = entry.status == HistoryStatus.completed ? 'Completed' : 'Failed';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(entry.prompt, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(_formatDate(entry.createdAt)),
        const SizedBox(height: 4),
        Text(
          '${labelForStyle(entry.options.style)} · ${entry.options.aspectRatio} · ${labelForQuality(entry.options.quality)}',
        ),
        const SizedBox(height: 4),
        Text(status),
      ],
    );
  }
}

Widget _thumbnail(HistoryEntry entry) {
  final String? path = entry.imagePath;
  if (path == null || !File(path).existsSync()) {
    return const _MissingImage();
  }
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Image.file(File(path), width: 88, height: 88, fit: BoxFit.cover),
  );
}

class _MissingImage extends StatelessWidget {
  const _MissingImage();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 88,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text('No image', textAlign: TextAlign.center),
    );
  }
}

String _formatDate(DateTime value) {
  final DateTime local = value.toLocal();
  final String month = local.month.toString().padLeft(2, '0');
  final String day = local.day.toString().padLeft(2, '0');
  final String hour = local.hour.toString().padLeft(2, '0');
  final String minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}
