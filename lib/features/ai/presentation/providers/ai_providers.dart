import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../di/ai_providers.dart';
import '../../domain/services/ai_service.dart';

class AiSuggestionsState {
  final List<Suggestion> suggestions;
  final bool loading;
  final String? error;

  const AiSuggestionsState({
    this.suggestions = const [],
    this.loading = false,
    this.error,
  });

  AiSuggestionsState copyWith({
    List<Suggestion>? suggestions,
    bool? loading,
    String? error,
  }) {
    return AiSuggestionsState(
      suggestions: suggestions ?? this.suggestions,
      loading: loading ?? this.loading,
      error: error ?? this.error,
    );
  }
}

class AiSuggestionsNotifier extends StateNotifier<AiSuggestionsState> {
  final AiService _service;

  AiSuggestionsNotifier(this._service) : super(const AiSuggestionsState());

  Future<void> load() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, error: null);
    try {
      final suggestions = await _service.getSuggestions();
      state = state.copyWith(suggestions: suggestions, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  void markRead(int id) {
    state = state.copyWith(
      suggestions: state.suggestions.map((s) {
        return s.id == id ? s.copyWith(isRead: true) : s;
      }).toList(),
    );
  }

  void deleteOne(int id) {
    state = state.copyWith(
      suggestions: state.suggestions.where((s) => s.id != id).toList(),
    );
  }

  void markAllRead() {
    state = state.copyWith(
      suggestions: state.suggestions.map((s) => s.copyWith(isRead: true)).toList(),
    );
  }

  Future<void> generate() async {
    final suggestions = await _service.getSuggestions();
    state = state.copyWith(suggestions: suggestions, loading: false);
  }
}

final aiSuggestionsProvider =
    StateNotifierProvider<AiSuggestionsNotifier, AiSuggestionsState>((ref) {
  final service = ref.watch(aiServiceProvider);
  return AiSuggestionsNotifier(service);
});
