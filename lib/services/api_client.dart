import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../domain/entities.dart';
import 'secure_vault.dart';
import 'settings_service.dart';

typedef DiagnosticSink = void Function(Map<String, Object?> event);
typedef _RoundDiagnosticSink =
    void Function(String event, Map<String, Object?> values);

/// Rehydrates durable message parts into the structured tool history expected
/// by OpenAI-compatible chat APIs.
///
/// A ClaudeChat assistant message can contain several model/tool rounds. The
/// database keeps those rounds as ordered parts, so replaying only
/// `role + content` makes a long conversation look as if the model merely
/// claimed to use tools. This builder restores each assistant tool call and
/// its matching `role: tool` receipt.
@visibleForTesting
List<Map<String, Object?>> buildToolAwareApiMessages({
  required List<ChatMessage> messages,
  Map<String, List<MessagePart>> messagePartsByMessage =
      const <String, List<MessagePart>>{},
  Map<String, Object?>? lastUserContent,
}) {
  final output = <Map<String, Object?>>[];
  for (var messageIndex = 0; messageIndex < messages.length; messageIndex++) {
    final message = messages[messageIndex];
    final isLastUser =
        messageIndex == messages.length - 1 && message.role == 'user';
    if (message.role != 'assistant') {
      output.add(<String, Object?>{
        'role': message.role,
        'content': isLastUser && lastUserContent != null
            ? lastUserContent['content']
            : message.content,
      });
      continue;
    }

    final parts = messagePartsByMessage[message.id] ?? const <MessagePart>[];
    final toolParts = parts
        .where(
          (part) =>
              part.type == 'tool' &&
              part.metadata['status'] != 'preparing' &&
              part.metadata['status'] != 'running',
        )
        .toList();
    if (toolParts.isEmpty) {
      output.add(<String, Object?>{
        'role': 'assistant',
        'content': message.content,
      });
      continue;
    }

    final hasContentPart = parts.any(
      (part) => part.type == 'content' && (part.content ?? '').isNotEmpty,
    );
    var pendingText = StringBuffer();
    if (!hasContentPart && message.content.isNotEmpty) {
      pendingText.write(message.content);
    }
    var partIndex = 0;
    while (partIndex < parts.length) {
      final part = parts[partIndex];
      if (part.type == 'content') {
        pendingText.write(part.content ?? '');
        partIndex++;
        continue;
      }
      if (part.type != 'tool' ||
          part.metadata['status'] == 'preparing' ||
          part.metadata['status'] == 'running') {
        partIndex++;
        continue;
      }

      final group = <MessagePart>[];
      while (partIndex < parts.length) {
        final candidate = parts[partIndex];
        if (candidate.type != 'tool') break;
        if (candidate.metadata['status'] != 'preparing' &&
            candidate.metadata['status'] != 'running') {
          group.add(candidate);
        }
        partIndex++;
      }
      final calls = <Map<String, Object?>>[];
      final receipts = <Map<String, Object?>>[];
      for (final tool in group) {
        final metadata = tool.metadata;
        final name = '${metadata['name'] ?? ''}'.trim();
        if (name.isEmpty) continue;
        final callId = '${metadata['callId'] ?? ''}'.trim().isEmpty
            ? 'history-${message.id}-${tool.sequence}'
            : '${metadata['callId']}';
        final rawArguments = metadata['arguments'];
        final arguments = rawArguments is String
            ? rawArguments
            : jsonEncode(rawArguments is Map ? rawArguments : const {});
        calls.add(<String, Object?>{
          'id': callId,
          'type': 'function',
          'function': <String, Object?>{'name': name, 'arguments': arguments},
        });
        receipts.add(<String, Object?>{
          'role': 'tool',
          'tool_call_id': callId,
          'name': name,
          'content': (tool.content ?? '').isEmpty ? '{}' : tool.content,
        });
      }
      if (calls.isEmpty) continue;
      output.add(<String, Object?>{
        'role': 'assistant',
        'content': pendingText.toString(),
        'tool_calls': calls,
      });
      output.addAll(receipts);
      pendingText = StringBuffer();
    }
    if (pendingText.isNotEmpty) {
      output.add(<String, Object?>{
        'role': 'assistant',
        'content': pendingText.toString(),
      });
    }
  }
  return output;
}

class ApiClient {
  static const Set<String> _fileToolNames = <String>{
    'search_files',
    'read_file',
    'create_file',
    'edit_file',
    'delete_file',
    'list_workspace_files',
    'read_workspace_file',
    'list_workspace_file_versions',
    'read_workspace_file_version',
    'restore_workspace_file_version',
    'create_workspace_file',
    'edit_workspace_file',
  };

  ApiClient(
    this.vault, {
    http.Client? client,
    this.requestTimeout = const Duration(minutes: 3),
    this.responseIdleTimeout = const Duration(minutes: 10),
    this.toolProgressMinDuration = const Duration(milliseconds: 260),
  }) : _client = client ?? http.Client();

  final SecureVault vault;
  final http.Client _client;
  final Duration requestTimeout;
  final Duration responseIdleTimeout;
  final Duration toolProgressMinDuration;

  Future<List<String>> models(ApiProfile profile) async {
    final endpoint = _endpoint(profile.endpoint, models: true);
    final request = http.Request('GET', endpoint)
      ..followRedirects = false
      ..headers.addAll(await _headers(profile));
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw HttpException('模型列表请求失败 (${streamed.statusCode})');
    }
    final data = jsonDecode(await _readBody(streamed.stream));
    final items = data is Map ? data['data'] : null;
    if (items is! List) return const <String>[];
    return items
        .map((item) => item is Map ? '${item['id'] ?? ''}' : '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  Stream<String> chat({
    required ApiProfile profile,
    required String model,
    required List<ChatMessage> messages,
    Map<String, Object?>? lastUserContent,
    required String systemPrompt,
    double temperature = 0.7,
    int? maxTokens,
    bool stream = true,
  }) async* {
    final endpoint = _endpoint(profile.endpoint);
    final request = http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers.addAll(await _headers(profile))
      ..body = jsonEncode(<String, Object?>{
        'model': model,
        'messages': <Map<String, Object?>>[
          if (systemPrompt.trim().isNotEmpty)
            <String, String>{'role': 'system', 'content': systemPrompt.trim()},
          ...messages.indexed.map(
            (entry) => <String, Object?>{
              'role': entry.$2.role,
              'content':
                  entry.$1 == messages.length - 1 &&
                      entry.$2.role == 'user' &&
                      lastUserContent != null
                  ? lastUserContent['content']
                  : entry.$2.content,
            },
          ),
        ],
        'temperature': temperature,
        'max_tokens': ?maxTokens,
        'stream': stream,
      });
    final response = await _client.send(request).timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await _readBody(response.stream);
      throw HttpException(_safeError(response.statusCode, body));
    }
    if (!stream) {
      final data = jsonDecode(await _readBody(response.stream));
      Object? message;
      if (data is Map &&
          data['choices'] is List &&
          (data['choices'] as List).isNotEmpty) {
        final first = (data['choices'] as List).first;
        if (first is Map) message = first['message'];
      }
      if (message is Map && message['content'] is String)
        yield message['content']! as String;
      return;
    }
    final lines = response.stream
        .timeout(responseIdleTimeout)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final payload = _streamPayload(line);
      if (payload == null) continue;
      if (payload == '[DONE]') break;
      if (payload.isEmpty) continue;
      try {
        final data = jsonDecode(payload);
        final choices = data is Map ? data['choices'] : null;
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final delta = (choices.first as Map)['delta'];
          final text = delta is Map ? delta['content'] : null;
          if (text is String && text.isNotEmpty) yield text;
        }
      } on FormatException {
        // Ignore keepalives and provider-specific non-JSON SSE events.
      }
    }
  }

  Future<ChatCompletionResult> chatWithTools({
    required ApiProfile profile,
    required String model,
    required List<ChatMessage> messages,
    Map<String, List<MessagePart>> messagePartsByMessage =
        const <String, List<MessagePart>>{},
    required String systemPrompt,
    String? systemPromptWithoutTools,
    required List<Map<String, Object?>> tools,
    required Future<String> Function(
      String callId,
      String name,
      Map<String, Object?> arguments,
    )
    executeTool,
    Map<String, Object?>? lastUserContent,
    void Function(String chunk)? onText,
    void Function(String chunk)? onReasoning,
    void Function(ChatCompletionPart part)? onToolEvent,
    void Function(ChatCompletionPart? part)? onToolProgress,
    VoidCallback? onActivity,
    double? temperature = 0.7,
    double? topP = 1,
    double? frequencyPenalty = 0,
    double? presencePenalty = 0,
    int? maxTokens,
    bool stream = true,
    bool? thinkingEnabled,
    String? reasoningEffort,
    int maxRounds = 10,
    Future<void>? abortTrigger,
    Map<String, Object?> diagnosticContext = const <String, Object?>{},
    DiagnosticSink? onDiagnostic,
  }) async {
    final stopwatch = Stopwatch()..start();
    final endpoint = _endpoint(profile.endpoint);
    final reasoningRequest = _reasoningRequestFields(
      endpoint: endpoint,
      model: model,
      enabled: thinkingEnabled,
      effort: reasoningEffort,
    );
    final plainHistory = messages.indexed
        .map(
          (entry) => <String, Object?>{
            'role': entry.$2.role,
            'content':
                entry.$1 == messages.length - 1 &&
                    entry.$2.role == 'user' &&
                    lastUserContent != null
                ? lastUserContent['content']
                : entry.$2.content,
          },
        )
        .toList(growable: false);
    final structuredHistory = buildToolAwareApiMessages(
      messages: messages,
      messagePartsByMessage: messagePartsByMessage,
      lastUserContent: lastUserContent,
    );
    final apiMessages = <Map<String, Object?>>[
      if (systemPrompt.trim().isNotEmpty)
        <String, Object?>{'role': 'system', 'content': systemPrompt.trim()},
      ...(tools.isEmpty ? plainHistory : structuredHistory),
    ];
    void emit(String event, [Map<String, Object?> values = const {}]) {
      onDiagnostic?.call(<String, Object?>{
        ...diagnosticContext,
        'event': event,
        ...values,
      });
    }

    final restoredToolCalls = apiMessages.fold<int>(
      0,
      (total, message) =>
          total + ((message['tool_calls'] as List?)?.length ?? 0),
    );
    emit('chat_request_started', <String, Object?>{
      'model': model,
      'endpointHost': endpoint.host,
      'endpointPath': endpoint.path,
      'storedMessageCount': messages.length,
      'apiMessageCount': apiMessages.length,
      'restoredHistoricalToolCalls': restoredToolCalls,
      'toolDefinitionCount': tools.length,
      'toolNames': tools
          .map((tool) => '${(tool['function'] as Map?)?['name'] ?? ''}')
          .where((name) => name.isNotEmpty)
          .toList(),
      'stream': stream,
      'thinkingRequested': reasoningRequest.isNotEmpty ? thinkingEnabled : null,
      'reasoningEffort': reasoningRequest['reasoning_effort'],
      'maxRounds': maxRounds,
    });
    final finalText = StringBuffer();
    final parts = <ChatCompletionPart>[];
    final usage = <String, Object?>{};
    var consecutiveFailedToolRounds = 0;
    var consecutiveRepeatedToolRounds = 0;
    var lastToolAttemptSignature = '';
    var hasSuccessfulToolResult = false;
    for (var round = 0; round < maxRounds; round++) {
      final basePayload = <String, Object?>{
        'model': model,
        'messages': apiMessages,
        'temperature': ?temperature,
        'top_p': ?topP,
        'frequency_penalty': ?frequencyPenalty,
        'presence_penalty': ?presencePenalty,
        'max_tokens': ?maxTokens,
        'stream': stream,
        ...reasoningRequest,
        if (tools.isNotEmpty) 'tools': tools,
        if (tools.isNotEmpty) 'tool_choice': 'auto',
      };
      emit('model_round_started', <String, Object?>{
        'round': round + 1,
        'apiMessageCount': apiMessages.length,
        'payloadBytes': utf8.encode(jsonEncode(basePayload)).length,
      });
      late final _RoundResult result;
      try {
        result = await _completionRoundWithCompat(
          endpoint: endpoint,
          headers: await _headers(profile),
          payload: basePayload,
          preferStream: stream,
          abortTrigger: abortTrigger,
          onText: (chunk) {
            finalText.write(chunk);
            onText?.call(chunk);
          },
          onReasoning: onReasoning,
          onToolProgress: onToolProgress,
          onActivity: onActivity,
          onDiagnostic: emit,
          round: round + 1,
        );
      } on Object catch (error) {
        if (tools.isEmpty || !_isToolCompatibilityError(error)) rethrow;
        emit('tool_compatibility_fallback', <String, Object?>{
          'round': round + 1,
          'error': '$error',
        });
        final unavailablePart = ChatCompletionPart(
          type: 'status',
          metadata: <String, Object?>{
            'status': 'tools_unavailable',
            'detail': '当前接口不兼容工具调用，本轮没有执行本地数据操作。',
          },
        );
        parts.add(unavailablePart);
        onToolEvent?.call(unavailablePart);
        onToolProgress?.call(null);
        final fallbackMessages = <Map<String, Object?>>[
          if ((systemPromptWithoutTools ?? '').trim().isNotEmpty)
            <String, Object?>{
              'role': 'system',
              'content': systemPromptWithoutTools!.trim(),
            },
          ...plainHistory,
        ];
        final fallback = await _completionRoundWithCompat(
          endpoint: endpoint,
          headers: await _headers(profile),
          payload: <String, Object?>{
            ...basePayload,
            'messages': fallbackMessages,
          }..removeWhere((key, _) => key == 'tools' || key == 'tool_choice'),
          preferStream: stream,
          abortTrigger: abortTrigger,
          onText: (chunk) {
            finalText.write(chunk);
            onText?.call(chunk);
          },
          onReasoning: onReasoning,
          onToolProgress: onToolProgress,
          onActivity: onActivity,
          onDiagnostic: emit,
          round: round + 1,
        );
        _accumulateUsage(usage, fallback.usage);
        _appendRoundParts(fallback, parts, onToolEvent);
        onToolProgress?.call(null);
        stopwatch.stop();
        return ChatCompletionResult(
          text: finalText.toString(),
          parts: parts,
          usage: usage,
          elapsed: stopwatch.elapsed,
        );
      }
      emit('model_round_completed', <String, Object?>{
        'round': round + 1,
        'finishReason': result.finishReason,
        'textCharacters': result.text.length,
        'reasoningCharacters': result.reasoning.length,
        'toolCallCount': result.toolCalls.length,
        'toolNames': result.toolCalls.map((call) => call.name).toList(),
        'toolArgumentBytes': result.toolCalls
            .map((call) => utf8.encode(call.arguments).length)
            .toList(),
        'usage': result.usage,
      });
      _accumulateUsage(usage, result.usage);
      _appendRoundParts(result, parts, onToolEvent);
      if (result.toolCalls.isEmpty) {
        onToolProgress?.call(null);
        stopwatch.stop();
        return ChatCompletionResult(
          text: finalText.toString(),
          parts: parts,
          usage: usage,
          elapsed: stopwatch.elapsed,
        );
      }
      final signature = _toolAttemptSignature(result.toolCalls);
      if (signature == lastToolAttemptSignature) {
        consecutiveRepeatedToolRounds++;
      } else {
        lastToolAttemptSignature = signature;
        consecutiveRepeatedToolRounds = 1;
      }
      if (consecutiveRepeatedToolRounds >= maxRounds) {
        if (!hasSuccessfulToolResult) {
          throw const HttpException('工具连续重复调用同一参数，已停止以避免循环');
        }
        final stopText = '已完成部分工具调用。检测到模型连续重复同一组工具调用，我先停在这里。';
        finalText.write(stopText);
        final stopPart = ChatCompletionPart(type: 'content', content: stopText);
        parts.add(stopPart);
        onToolEvent?.call(stopPart);
        stopwatch.stop();
        return ChatCompletionResult(
          text: finalText.toString(),
          parts: parts,
          usage: usage,
          elapsed: stopwatch.elapsed,
        );
      }
      apiMessages.add(<String, Object?>{
        'role': 'assistant',
        'content': result.text.isEmpty ? null : result.text,
        'tool_calls': result.toolCalls.map((call) => call.toApi()).toList(),
        if (result.reasoning.isNotEmpty) 'reasoning_content': result.reasoning,
      });
      var roundHadSuccessfulTool = false;
      for (final call in result.toolCalls) {
        Map<String, Object?> arguments = <String, Object?>{};
        String toolOutput;
        var status = 'success';
        final progressStopwatch = Stopwatch();
        try {
          arguments = call.arguments.trim().isEmpty
              ? <String, Object?>{}
              : (jsonDecode(call.arguments) as Map).cast<String, Object?>();
          if (onToolProgress != null) {
            progressStopwatch.start();
            onToolProgress(
              ChatCompletionPart(
                type: 'tool',
                content: '{}',
                metadata: <String, Object?>{
                  'callId': call.id,
                  'name': call.name,
                  'arguments': arguments,
                  'status': 'preparing',
                },
              ),
            );
            // Give Flutter one event-loop turn to paint the preparation state
            // even when a local tool completes almost immediately.
            await Future<void>.delayed(Duration.zero);
          }
          onToolProgress?.call(
            ChatCompletionPart(
              type: 'tool',
              content: '{}',
              metadata: <String, Object?>{
                'callId': call.id,
                'name': call.name,
                'arguments': arguments,
                'status': 'running',
              },
            ),
          );
          onActivity?.call();
          emit('tool_execution_started', <String, Object?>{
            'round': round + 1,
            'callId': call.id,
            'toolName': call.name,
            'argumentKeys': arguments.keys.toList(),
            'argumentBytes': utf8.encode(call.arguments).length,
          });
          toolOutput = await executeTool(call.id, call.name, arguments);
        } on FormatException catch (error) {
          status = 'error';
          toolOutput = jsonEncode(<String, Object?>{
            'ok': false,
            'tool': call.name,
            'error': '参数解析失败：${error.message}',
          });
        } on TypeError {
          status = 'error';
          toolOutput = jsonEncode(<String, Object?>{
            'ok': false,
            'tool': call.name,
            'error': '参数解析失败：invalid JSON',
          });
        } on Object catch (error) {
          status = 'error';
          toolOutput = jsonEncode(<String, Object?>{
            'ok': false,
            'tool': call.name,
            'error': '$error',
          });
        }
        if (progressStopwatch.isRunning) {
          progressStopwatch.stop();
          final remaining = toolProgressMinDuration - progressStopwatch.elapsed;
          if (remaining > Duration.zero) {
            await Future<void>.delayed(remaining);
          }
        }
        onActivity?.call();
        Object? displayResult = toolOutput;
        try {
          final decoded = jsonDecode(toolOutput);
          if (decoded is Map) {
            if (decoded['pendingApproval'] != null) {
              status = 'pending_approval';
              displayResult = <String, Object?>{
                'pendingApproval': decoded['pendingApproval'],
                'label': decoded['label'],
              };
            } else if (decoded['ok'] == false || decoded['error'] != null) {
              status = decoded['denied'] == true ? 'denied' : 'error';
              displayResult = <String, Object?>{
                'error': decoded['error'] ?? '工具执行失败',
              };
            } else if (decoded['ok'] == true && decoded.containsKey('result')) {
              displayResult = decoded['result'];
            } else {
              displayResult = decoded;
            }
          }
        } on FormatException {
          // Plain text is a valid tool response.
        }
        final isUserFileWrite =
            call.name == 'create_file' || call.name == 'edit_file';
        final isWorkspaceFileWrite =
            call.name == 'create_workspace_file' ||
            call.name == 'edit_workspace_file' ||
            call.name == 'restore_workspace_file_version';
        final hasVerifiedFileWrite =
            displayResult is Map &&
            displayResult['verified'] == true &&
            '${displayResult['id'] ?? displayResult['fileId'] ?? ''}'
                .isNotEmpty &&
            '${displayResult['sha256'] ?? ''}'.isNotEmpty &&
            (!isUserFileWrite ||
                '${displayResult['versionId'] ?? ''}'.isNotEmpty);
        if (status == 'success' &&
            (isUserFileWrite || isWorkspaceFileWrite) &&
            !hasVerifiedFileWrite) {
          status = 'error';
          const message = '文件写入未返回完整性证明，不能判定为成功';
          displayResult = const <String, Object?>{'error': message};
          toolOutput = jsonEncode(<String, Object?>{
            'ok': false,
            'tool': call.name,
            'error': message,
          });
        }
        final succeeded = status == 'success';
        emit('tool_execution_completed', <String, Object?>{
          'round': round + 1,
          'callId': call.id,
          'toolName': call.name,
          'status': status,
          'resultBytes': utf8.encode(toolOutput).length,
          'verified': displayResult is Map && displayResult['verified'] == true,
          if (status != 'success')
            'error': displayResult is Map
                ? '${displayResult['error'] ?? '工具执行失败'}'
                : '工具执行失败',
        });
        roundHadSuccessfulTool = roundHadSuccessfulTool || succeeded;
        hasSuccessfulToolResult = hasSuccessfulToolResult || succeeded;
        final toolPart = ChatCompletionPart(
          type: 'tool',
          content: jsonEncode(displayResult),
          metadata: <String, Object?>{
            'callId': call.id,
            'name': call.name,
            'arguments': arguments,
            'status': status,
          },
        );
        // The transient preparation/running state is rendered as the single
        // response-status capsule. Persist only the durable tool receipt so a
        // long multi-tool answer does not leave a stack of lifecycle pills.
        onToolProgress?.call(null);
        parts.add(toolPart);
        onToolEvent?.call(toolPart);
        apiMessages.add(<String, Object?>{
          'role': 'tool',
          'tool_call_id': call.id,
          'name': call.name,
          'content': toolOutput,
        });
      }
      if (roundHadSuccessfulTool) {
        consecutiveFailedToolRounds = 0;
      } else {
        consecutiveFailedToolRounds++;
        if (consecutiveFailedToolRounds >= maxRounds) {
          throw const HttpException('工具连续调用失败，已停止以避免循环');
        }
      }
    }
    stopwatch.stop();
    if (hasSuccessfulToolResult) {
      const stopText = '已完成部分工具调用。为避免循环，我先停在这里。';
      finalText.write(stopText);
      final part = const ChatCompletionPart(type: 'content', content: stopText);
      parts.add(part);
      onToolEvent?.call(part);
      return ChatCompletionResult(
        text: finalText.toString(),
        parts: parts,
        usage: usage,
        elapsed: stopwatch.elapsed,
      );
    }
    throw HttpException('工具调用轮次超过上限 $maxRounds 次');
  }

  void _appendRoundParts(
    _RoundResult result,
    List<ChatCompletionPart> parts,
    void Function(ChatCompletionPart part)? onToolEvent,
  ) {
    if (result.reasoning.isNotEmpty) {
      final part = ChatCompletionPart(
        type: 'thought',
        content: result.reasoning,
      );
      parts.add(part);
      onToolEvent?.call(part);
    }
    if (result.text.isNotEmpty) {
      final part = ChatCompletionPart(type: 'content', content: result.text);
      parts.add(part);
      onToolEvent?.call(part);
    }
  }

  String _toolAttemptSignature(List<_ToolCall> calls) => calls
      .map((call) {
        Object? arguments;
        try {
          arguments = jsonDecode(call.arguments);
        } on Object {
          arguments = call.arguments.replaceAll(RegExp(r'\s+'), ' ').trim();
        }
        return '${call.name}:${jsonEncode(_stableValue(arguments))}';
      })
      .join('|');

  Object? _stableValue(Object? value) {
    if (value is List) return value.map(_stableValue).toList();
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((left, right) => '${left.key}'.compareTo('${right.key}'));
      return <String, Object?>{
        for (final entry in entries) '${entry.key}': _stableValue(entry.value),
      };
    }
    return value;
  }

  Future<_RoundResult> _completionRoundWithCompat({
    required Uri endpoint,
    required Map<String, String> headers,
    required Map<String, Object?> payload,
    required bool preferStream,
    Future<void>? abortTrigger,
    required void Function(String chunk) onText,
    void Function(String chunk)? onReasoning,
    void Function(ChatCompletionPart? part)? onToolProgress,
    VoidCallback? onActivity,
    _RoundDiagnosticSink? onDiagnostic,
    required int round,
  }) async {
    final payloads = <Map<String, Object?>>[
      payload,
      if (payload.containsKey('tool_choice'))
        <String, Object?>{...payload}..remove('tool_choice'),
    ];
    Object? streamError;
    if (preferStream) {
      streamPayloads:
      for (var index = 0; index < payloads.length; index++) {
        final variants = <Map<String, Object?>>[
          _withStreamUsage(payloads[index]),
          <String, Object?>{...payloads[index], 'stream': true},
        ];
        for (
          var variantIndex = 0;
          variantIndex < variants.length;
          variantIndex++
        ) {
          final text = StringBuffer();
          final reasoning = StringBuffer();
          var emitted = false;
          try {
            final result = await _completionRound(
              endpoint: endpoint,
              headers: headers,
              payload: variants[variantIndex],
              stream: true,
              abortTrigger: abortTrigger,
              onText: (chunk) {
                emitted = true;
                text.write(chunk);
                onText(chunk);
              },
              onReasoning: (chunk) {
                emitted = true;
                reasoning.write(chunk);
                onReasoning?.call(chunk);
              },
              onToolProgress: onToolProgress,
              onActivity: onActivity,
              onDiagnostic: onDiagnostic,
              round: round,
            );
            final invalidToolCall = _invalidToolCall(result);
            if (invalidToolCall != null) {
              final error = FormatException(
                _toolCallFailureMessage(result, invalidToolCall),
              );
              if (emitted) throw error;
              streamError = error;
              break streamPayloads;
            }
            if (result.text.isNotEmpty ||
                result.reasoning.isNotEmpty ||
                result.toolCalls.isNotEmpty) {
              return result;
            }
            streamError = const HttpException('流式工具响应为空');
            break streamPayloads;
          } on Object catch (error) {
            if (error is http.RequestAbortedException) rethrow;
            // Once visible SSE data has been delivered, retrying the same
            // round would duplicate that text. Preserve the partial response
            // and let the caller report the interrupted stream instead.
            if (emitted) rethrow;
            if (!_shouldRetryAsNonStream(error)) rethrow;
            streamError = error;
            // A number of OpenAI-compatible relays reject stream_options.
            // Retry the same request once without usage negotiation before
            // falling back to non-streaming mode.
            if (variantIndex == 0) continue;
            if (index == 0 && _isToolChoiceCompatibilityError(error)) {
              continue streamPayloads;
            }
            break streamPayloads;
          }
        }
      }
    }
    for (var index = 0; index < payloads.length; index++) {
      try {
        final result = await _completionRound(
          endpoint: endpoint,
          headers: headers,
          payload: <String, Object?>{...payloads[index], 'stream': false},
          stream: false,
          abortTrigger: abortTrigger,
          onText: onText,
          onReasoning: onReasoning,
          onToolProgress: onToolProgress,
          onActivity: onActivity,
          onDiagnostic: onDiagnostic,
          round: round,
        );
        final invalidToolCall = _invalidToolCall(result);
        if (invalidToolCall != null) {
          throw FormatException(
            _toolCallFailureMessage(result, invalidToolCall),
          );
        }
        return result;
      } on Object catch (error) {
        if (index == 0 && _isToolChoiceCompatibilityError(error)) continue;
        if (streamError != null) {
          throw HttpException('$error；流式工具尝试：$streamError');
        }
        rethrow;
      }
    }
    throw HttpException(
      streamError == null
          ? '工具接口没有返回可显示内容'
          : '工具接口没有返回可显示内容；流式工具尝试：$streamError',
    );
  }

  bool _isToolChoiceCompatibilityError(Object error) {
    final text = '$error';
    return RegExp(
      r'tool_choice|tool choice|unknown.*choice|unsupported.*choice|extra.*choice',
      caseSensitive: false,
    ).hasMatch(text);
  }

  bool _isToolCompatibilityError(Object error) {
    final text = '$error';
    final compatibleStatus =
        RegExp(r'\((400|404|422)\)').hasMatch(text) ||
        !RegExp(r'\(\d{3}\)').hasMatch(text);
    return compatibleStatus &&
        RegExp(
          r'tool|function|工具|函数|tool_calls|tool_choice',
          caseSensitive: false,
        ).hasMatch(text);
  }

  bool _shouldRetryAsNonStream(Object error) {
    final text = '$error';
    final status = RegExp(r'\((\d{3})\)').firstMatch(text)?.group(1);
    if (status == null) return true;
    return status == '400' ||
        status == '406' ||
        status == '415' ||
        status == '422';
  }

  Future<_RoundResult> _completionRound({
    required Uri endpoint,
    required Map<String, String> headers,
    required Map<String, Object?> payload,
    required bool stream,
    Future<void>? abortTrigger,
    required void Function(String chunk) onText,
    void Function(String chunk)? onReasoning,
    void Function(ChatCompletionPart? part)? onToolProgress,
    VoidCallback? onActivity,
    _RoundDiagnosticSink? onDiagnostic,
    required int round,
  }) async {
    final requestStopwatch = Stopwatch()..start();
    final request =
        http.AbortableRequest('POST', endpoint, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..headers.addAll(headers)
          ..body = jsonEncode(payload);
    final response = await _client.send(request).timeout(requestTimeout);
    onActivity?.call();
    onDiagnostic?.call('http_response_received', <String, Object?>{
      'round': round,
      'statusCode': response.statusCode,
      'stream': stream,
      'responseHeaderNames': response.headers.keys.toList(),
      'headersElapsedMs': requestStopwatch.elapsedMilliseconds,
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await _readBody(response.stream);
      onDiagnostic?.call('http_response_failed', <String, Object?>{
        'round': round,
        'statusCode': response.statusCode,
        'error': _safeError(response.statusCode, body),
        'responseBytes': utf8.encode(body).length,
      });
      throw HttpException(_safeError(response.statusCode, body));
    }
    if (!stream) {
      final body = await _readBody(response.stream);
      final data = jsonDecode(body);
      onActivity?.call();
      final choice =
          data is Map &&
              data['choices'] is List &&
              (data['choices'] as List).isNotEmpty
          ? (data['choices'] as List).first
          : null;
      final message = choice is Map ? choice['message'] : null;
      final text = _replyText(data, message);
      var reasoning = message is Map ? _reasoningText(message) : '';
      if (reasoning.isEmpty && choice is Map) {
        reasoning = _reasoningText(choice);
      }
      if (reasoning.isEmpty && data is Map) {
        reasoning = _reasoningText(data);
      }
      if (reasoning.isNotEmpty) onReasoning?.call(reasoning);
      if (text.isNotEmpty) onText(text);
      final result = _RoundResult(
        text: text,
        reasoning: reasoning,
        usage: data is Map ? _extractUsage(data) : const {},
        toolCalls: data is Map ? _extractToolCalls(data) : const <_ToolCall>[],
        finishReason: choice is Map ? '${choice['finish_reason'] ?? ''}' : '',
      );
      onDiagnostic?.call('non_stream_response_parsed', <String, Object?>{
        'round': round,
        'responseBytes': utf8.encode(body).length,
        'finishReason': result.finishReason,
        'toolCallCount': result.toolCalls.length,
        'toolNames': result.toolCalls.map((call) => call.name).toList(),
      });
      return result;
    }
    final text = StringBuffer();
    final reasoningBuffer = StringBuffer();
    final usage = <String, Object?>{};
    final calls = <int, _MutableToolCall>{};
    final announcedToolNames = <int, String>{};
    var finishReason = '';
    var sseEventCount = 0;
    var malformedEventCount = 0;
    var toolDeltaCount = 0;
    int? firstEventElapsedMs;
    final lines = response.stream
        .timeout(
          responseIdleTimeout,
          onTimeout: (sink) {
            final activeFileTools = calls.values
                .map((call) => call.currentName.trim())
                .where(_fileToolNames.contains)
                .toSet()
                .toList(growable: false);
            if (activeFileTools.isNotEmpty) {
              // Large streamed file arguments can legitimately pause while
              // the provider prepares the next chunk. Emit a zero-byte
              // keepalive so Stream.timeout starts a fresh idle window, but
              // only after a real file tool name has arrived. A reply that
              // has produced neither content nor a file operation still
              // times out normally.
              onActivity?.call();
              onDiagnostic?.call(
                'response_idle_extended_for_file_tool',
                <String, Object?>{
                  'round': round,
                  'toolNames': activeFileTools,
                  'elapsedMs': requestStopwatch.elapsedMilliseconds,
                },
              );
              sink.add(const <int>[]);
              return;
            }
            sink.addError(
              TimeoutException(
                '长时间没有收到新数据',
                responseIdleTimeout,
              ),
            );
            sink.close();
          },
        )
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      onActivity?.call();
      final raw = _streamPayload(line);
      if (raw == null) continue;
      if (raw == '[DONE]') break;
      if (raw.isEmpty) continue;
      sseEventCount++;
      firstEventElapsedMs ??= requestStopwatch.elapsedMilliseconds;
      try {
        final data = jsonDecode(raw);
        if (data is Map) _overlayUsage(usage, _extractUsage(data));
        if (data is! Map) continue;
        final choices = data['choices'];
        final choice = choices is List && choices.isNotEmpty
            ? choices.first
            : null;
        if (choice is Map && choice['finish_reason'] != null) {
          finishReason = '${choice['finish_reason']}';
        } else if (data['status'] != null) {
          finishReason = '${data['status']}';
        } else if (data['response'] is Map &&
            (data['response']! as Map)['status'] != null) {
          finishReason = '${(data['response']! as Map)['status']}';
        }
        final delta = choice is Map && choice['delta'] is Map
            ? choice['delta']! as Map
            : <Object?, Object?>{};
        var content = _textContent(delta['content'] ?? delta['text']);
        if (data['type'] == 'response.output_text.delta') {
          content = _textContent(data['delta']);
        }
        if (data['type'] == 'content_block_delta' && data['delta'] is Map) {
          final blockDelta = data['delta']! as Map;
          if (blockDelta['type'] == 'text_delta') {
            content = _textContent(blockDelta['text']);
          }
        }
        if (content.isNotEmpty) {
          text.write(content);
          onText(content);
        }
        var reasoningChunk = _reasoningText(delta);
        // A number of OpenAI-compatible gateways (notably recent GLM
        // adapters) put reasoning next to `choices[].delta` or use camelCase
        // names.  Workspace and ordinary chat share this parser; normalize
        // every known envelope here so neither surface can silently lose it.
        if (reasoningChunk.isEmpty && choice is Map) {
          reasoningChunk = _reasoningText(choice);
        }
        if (reasoningChunk.isEmpty) {
          reasoningChunk = _reasoningText(data);
        }
        if (data['type'] == 'content_block_delta' && data['delta'] is Map) {
          final blockDelta = data['delta']! as Map;
          if ('${blockDelta['type']}'.contains('thinking')) {
            reasoningChunk = _textContent(
              blockDelta['thinking'] ?? blockDelta['text'],
            );
          }
        }
        if ('${data['type']}'.contains('reasoning') ||
            '${data['type']}'.contains('thinking')) {
          reasoningChunk = reasoningChunk.isNotEmpty
              ? reasoningChunk
              : _textContent(data['delta'] ?? data['text']);
        }
        if (reasoningChunk.isNotEmpty) {
          reasoningBuffer.write(reasoningChunk);
          onReasoning?.call(reasoningChunk);
        }
        final toolDeltas = delta['tool_calls'];
        if (toolDeltas is List) {
          toolDeltaCount += toolDeltas.length;
          for (final value in toolDeltas.whereType<Map>()) {
            final index = (value['index'] as num?)?.toInt() ?? 0;
            final call = calls.putIfAbsent(index, _MutableToolCall.new);
            if (value['id'] is String) call.id = value['id']! as String;
            final function = value['function'];
            if (function is Map) {
              if (function['name'] is String)
                call.addName(function['name']! as String);
              if (function['arguments'] is String)
                call.addArguments(function['arguments']! as String);
            }
            _announceToolPreparation(
              calls,
              index,
              announcedToolNames,
              onToolProgress,
            );
          }
        }
        if (delta['function_call'] is Map) {
          _mergeToolDelta(calls, delta['function_call']! as Map, 0);
          _announceToolPreparation(
            calls,
            0,
            announcedToolNames,
            onToolProgress,
          );
        }
        if (data['type'] == 'content_block_start' &&
            data['content_block'] is Map) {
          final block = data['content_block']! as Map;
          if (block['type'] == 'tool_use') {
            final index = (data['index'] as num?)?.toInt() ?? 0;
            final call = calls.putIfAbsent(index, _MutableToolCall.new);
            call.id = '${block['id'] ?? call.id}';
            call.addName('${block['name'] ?? ''}');
            if (block['input'] is Map && (block['input']! as Map).isNotEmpty) {
              call.addArguments(jsonEncode(block['input']));
            }
            _announceToolPreparation(
              calls,
              index,
              announcedToolNames,
              onToolProgress,
            );
          }
        }
        if (data['type'] == 'content_block_delta' && data['delta'] is Map) {
          final blockDelta = data['delta']! as Map;
          if (blockDelta['type'] == 'input_json_delta') {
            final index = (data['index'] as num?)?.toInt() ?? 0;
            calls
                .putIfAbsent(index, _MutableToolCall.new)
                .addArguments('${blockDelta['partial_json'] ?? ''}');
            _announceToolPreparation(
              calls,
              index,
              announcedToolNames,
              onToolProgress,
            );
          }
        }
        if (data['output'] is List) {
          for (final entry in _extractToolCalls(data).indexed) {
            final index = entry.$1;
            final call = entry.$2;
            final mutable = calls.putIfAbsent(index, _MutableToolCall.new);
            mutable.id = call.id;
            mutable.addName(call.name);
            mutable.addArguments(call.arguments);
            _announceToolPreparation(
              calls,
              index,
              announcedToolNames,
              onToolProgress,
            );
          }
        }
      } on FormatException {
        // Provider keepalive.
        malformedEventCount++;
      }
    }
    final result = _RoundResult(
      text: text.toString(),
      reasoning: reasoningBuffer.toString(),
      usage: usage,
      toolCalls: calls.entries
          .map((entry) => entry.value.freeze(entry.key))
          .toList(),
      finishReason: finishReason,
    );
    onDiagnostic?.call('stream_response_parsed', <String, Object?>{
      'round': round,
      'sseEventCount': sseEventCount,
      'malformedEventCount': malformedEventCount,
      'toolDeltaCount': toolDeltaCount,
      'firstEventElapsedMs': firstEventElapsedMs,
      'totalElapsedMs': requestStopwatch.elapsedMilliseconds,
      'finishReason': finishReason,
      'toolCallCount': result.toolCalls.length,
      'toolNames': result.toolCalls.map((call) => call.name).toList(),
    });
    return result;
  }

  void _announceToolPreparation(
    Map<int, _MutableToolCall> calls,
    int index,
    Map<int, String> announcedToolNames,
    void Function(ChatCompletionPart? part)? onToolProgress,
  ) {
    if (onToolProgress == null) return;
    final call = calls[index];
    if (call == null) return;
    final name = call.currentName.trim();
    if (name.isEmpty) return;
    final argumentLength = call.currentArguments.length;
    final progressBucket = argumentLength < 512
        ? 'start-${argumentLength ~/ 64}'
        : 'chunk-${argumentLength ~/ 512}';
    final signature = '$name|${call.id}|$progressBucket';
    if (announcedToolNames[index] == signature) return;
    announcedToolNames[index] = signature;
    onToolProgress(
      ChatCompletionPart(
        type: 'tool',
        content: '{}',
        metadata: <String, Object?>{
          'callId': call.id.isEmpty ? 'tool-$index' : call.id,
          'name': name,
          'arguments': _partialToolArguments(call.currentArguments),
          'partialArguments': true,
          'status': 'preparing',
        },
      ),
    );
  }

  Map<String, Object?> _partialToolArguments(String raw) {
    if (raw.trim().isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Tool arguments arrive as streamed JSON fragments. The read-only live
      // editor can still display complete string fields and the currently
      // growing content field before the final JSON object closes.
    }
    final output = <String, Object?>{};
    for (final key in const <String>['name', 'fileName', 'path', 'content']) {
      final value = _partialJsonStringField(raw, key);
      if (value != null) output[key] = value;
    }
    return output;
  }

  String? _partialJsonStringField(String raw, String key) {
    final match = RegExp('"${RegExp.escape(key)}"\\s*:\\s*"').firstMatch(raw);
    if (match == null) return null;
    final encoded = StringBuffer();
    var escaped = false;
    for (var index = match.end; index < raw.length; index++) {
      final character = raw[index];
      if (!escaped && character == '"') break;
      encoded.write(character);
      if (escaped) {
        escaped = false;
      } else if (character == '\\') {
        escaped = true;
      }
    }
    var fragment = encoded.toString();
    if (fragment.endsWith('\\')) {
      fragment = fragment.substring(0, fragment.length - 1);
    }
    try {
      return jsonDecode('"$fragment"') as String;
    } on FormatException {
      return fragment
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\r', '\r')
          .replaceAll(r'\t', '\t')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', '\\');
    }
  }

  String? _invalidToolCall(_RoundResult result) {
    for (final call in result.toolCalls) {
      if (call.name.trim().isEmpty) return '工具名称为空';
      try {
        final decoded = call.arguments.trim().isEmpty
            ? const <String, Object?>{}
            : jsonDecode(call.arguments);
        if (decoded is! Map) return '${call.name} 的参数不是 JSON 对象';
      } on FormatException catch (error) {
        return '${call.name} 的参数 JSON 不完整：${error.message}';
      }
    }
    return null;
  }

  String _toolCallFailureMessage(_RoundResult result, String detail) {
    final reason = result.finishReason.toLowerCase();
    final limited =
        reason == 'length' ||
        reason.contains('max_token') ||
        reason.contains('max_output');
    if (limited) {
      return '文件或工具参数达到模型输出上限，内容不完整，尚未执行保存。$detail';
    }
    return '接口返回的流式工具参数不完整，已停止执行以避免产生残缺文件。$detail';
  }

  Map<String, Object?> _withStreamUsage(Map<String, Object?> payload) {
    final configured = payload['stream_options'];
    return <String, Object?>{
      ...payload,
      'stream': true,
      'stream_options': <String, Object?>{
        if (configured is Map)
          ...configured.map((key, value) => MapEntry('$key', value)),
        'include_usage': true,
      },
    };
  }

  Map<String, Object?> _extractUsage(Map data) {
    final result = <String, Object?>{};
    final response = data['response'];
    final message = data['message'];
    final delta = data['delta'];
    final candidates = <Object?>[
      data['usage'],
      data['usage_metadata'],
      data['usageMetadata'],
      if (response is Map) response['usage'],
      if (response is Map) response['usage_metadata'],
      if (response is Map) response['usageMetadata'],
      if (message is Map) message['usage'],
      if (delta is Map) delta['usage'],
    ];
    for (final candidate in candidates) {
      _overlayUsage(result, _usageMap(candidate));
    }
    if (result.isEmpty && _isUsageLikeMap(data)) {
      _overlayUsage(result, _usageMap(data));
    }
    return result;
  }

  bool _isUsageLikeMap(Map value) => const <String>{
    'prompt_tokens',
    'completion_tokens',
    'total_tokens',
    'input_tokens',
    'output_tokens',
    'prompt_cache_hit_tokens',
    'prompt_cache_miss_tokens',
    'cache_read_input_tokens',
    'cache_creation_input_tokens',
    'prompt_token_count',
    'candidates_token_count',
    'total_token_count',
    'cached_content_token_count',
    'thoughts_token_count',
    'promptTokenCount',
    'candidatesTokenCount',
    'inputTokenCount',
    'outputTokenCount',
    'totalTokenCount',
    'cachedContentTokenCount',
    'thoughtsTokenCount',
  }.any(value.containsKey);

  Map<String, Object?> _usageMap(Object? raw) => raw is Map
      ? raw.map((key, value) => MapEntry('$key', value))
      : const <String, Object?>{};

  void _accumulateUsage(
    Map<String, Object?> target,
    Map<String, Object?> incoming,
  ) {
    if (incoming.isEmpty) return;
    _mergeUsage(target, incoming);
    final current = target['_rounds'];
    final rounds = current is List ? current.cast<Object?>() : <Object?>[];
    rounds.add(_copyUsageValue(incoming));
    target['_rounds'] = rounds;
  }

  Object? _copyUsageValue(Object? value) {
    if (value is Map) {
      return value.map(
        (key, nested) => MapEntry('$key', _copyUsageValue(nested)),
      );
    }
    if (value is List) return value.map(_copyUsageValue).toList();
    return value;
  }

  void _mergeUsage(Map<String, Object?> target, Map<String, Object?> incoming) {
    for (final entry in incoming.entries) {
      final current = target[entry.key];
      final value = entry.value;
      if (current is num && value is num) {
        target[entry.key] = current + value;
      } else if (current is Map && value is Map) {
        final nested = current.cast<String, Object?>();
        _mergeUsage(nested, value.cast<String, Object?>());
        target[entry.key] = nested;
      } else if (value is Map) {
        target[entry.key] = value.map(
          (key, nestedValue) => MapEntry('$key', nestedValue),
        );
      } else if (value != null) {
        target[entry.key] = value;
      }
    }
  }

  void _overlayUsage(
    Map<String, Object?> target,
    Map<String, Object?> incoming,
  ) {
    for (final entry in incoming.entries) {
      final current = target[entry.key];
      final value = entry.value;
      if (current is Map && value is Map) {
        final nested = current.cast<String, Object?>();
        _overlayUsage(nested, value.cast<String, Object?>());
        target[entry.key] = nested;
      } else if (value != null) {
        target[entry.key] = value is Map
            ? value.map((key, nested) => MapEntry('$key', nested))
            : value;
      }
    }
  }

  String _reasoningText(Map value) {
    for (final key in const <String>[
      'reasoning_content',
      'reasoningContent',
      'reasoning_text',
      'reasoningText',
      'reasoning',
      'analysis_content',
      'analysisContent',
      'analysis',
      'thinking',
      'thought',
      'thoughts',
    ]) {
      final candidate = value[key];
      if (candidate is String && candidate.isNotEmpty) return candidate;
      if (candidate is Map) {
        final text =
            candidate['text'] ??
            candidate['content'] ??
            candidate['reasoning'] ??
            candidate['analysis'] ??
            candidate['thinking'];
        if (text is String && text.isNotEmpty) return text;
      }
      if (candidate is List) {
        final text = candidate
            .map((entry) {
              if (entry is String) return entry;
              if (entry is Map) {
                return _textContent(
                  entry['text'] ??
                      entry['content'] ??
                      entry['reasoning'] ??
                      entry['analysis'] ??
                      entry['thinking'],
                );
              }
              return '';
            })
            .where((entry) => entry.isNotEmpty)
            .join();
        if (text.isNotEmpty) return text;
      }
    }
    return '';
  }

  String? _streamPayload(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('data:')) return trimmed.substring(5).trim();
    if (trimmed == '[DONE]' || trimmed.startsWith('{')) return trimmed;
    return null;
  }

  Future<String> _readBody(Stream<List<int>> stream) =>
      http.ByteStream(stream.timeout(responseIdleTimeout)).bytesToString();

  String _textContent(Object? value) {
    if (value is String) return value;
    if (value is Map) {
      return _textContent(value['text'] ?? value['content']);
    }
    if (value is List) {
      return value.map(_textContent).where((item) => item.isNotEmpty).join('');
    }
    return '';
  }

  String _replyText(Object? data, Object? message) {
    if (message is Map) {
      final content = _textContent(message['content']);
      if (content.isNotEmpty) return content;
    }
    if (data is! Map) return '';
    final outputText = _textContent(data['output_text'] ?? data['text']);
    if (outputText.isNotEmpty) return outputText;
    final output = data['output'];
    if (output is List) {
      return output
          .whereType<Map>()
          .where((item) => item['type'] != 'function_call')
          .map((item) => _textContent(item['content'] ?? item['text']))
          .where((item) => item.isNotEmpty)
          .join('');
    }
    return '';
  }

  List<_ToolCall> _extractToolCalls(Map data) {
    final choices = data['choices'];
    final choice = choices is List && choices.isNotEmpty ? choices.first : null;
    final delta = choice is Map && choice['delta'] is Map
        ? choice['delta']! as Map
        : const <Object?, Object?>{};
    final message = choice is Map && choice['message'] is Map
        ? choice['message']! as Map
        : const <Object?, Object?>{};
    for (final source in <Map>[delta, message, data]) {
      final standard = _parseToolCalls(source['tool_calls']);
      if (standard.isNotEmpty) return standard;
      if (source['function_call'] is Map) {
        final call = _toolCallFromFunction(
          source['function_call']! as Map,
          id: '${source['id'] ?? ''}',
          index: 0,
        );
        if (call != null) return <_ToolCall>[call];
      }
    }
    final content = message['content'];
    if (content is List) {
      final anthropic = <_ToolCall>[];
      for (final block in content.whereType<Map>()) {
        if (block['type'] != 'tool_use' || '${block['name'] ?? ''}'.isEmpty) {
          continue;
        }
        anthropic.add(
          _ToolCall(
            id: '${block['id'] ?? 'tool-${anthropic.length}'}',
            name: '${block['name']}',
            arguments: jsonEncode(
              block['input'] is Map ? block['input'] : const {},
            ),
          ),
        );
      }
      if (anthropic.isNotEmpty) return anthropic;
    }
    final output = data['output'];
    if (output is List) {
      final responseCalls = <_ToolCall>[];
      for (final item in output.whereType<Map>()) {
        if (item['type'] != 'function_call' ||
            '${item['name'] ?? ''}'.isEmpty) {
          continue;
        }
        responseCalls.add(
          _ToolCall(
            id: '${item['call_id'] ?? item['id'] ?? 'tool-${responseCalls.length}'}',
            name: '${item['name']}',
            arguments: item['arguments'] is String
                ? item['arguments']! as String
                : jsonEncode(item['arguments'] ?? const {}),
          ),
        );
      }
      if (responseCalls.isNotEmpty) return responseCalls;
    }
    return const <_ToolCall>[];
  }

  _ToolCall? _toolCallFromFunction(
    Map function, {
    required String id,
    required int index,
  }) {
    final name = '${function['name'] ?? ''}';
    if (name.isEmpty) return null;
    final raw = function['arguments'] ?? const <String, Object?>{};
    return _ToolCall(
      id: id.isEmpty ? 'tool-$index' : id,
      name: name,
      arguments: raw is String ? raw : jsonEncode(raw),
    );
  }

  void _mergeToolDelta(
    Map<int, _MutableToolCall> calls,
    Map function,
    int index,
  ) {
    final call = calls.putIfAbsent(index, _MutableToolCall.new);
    if (function['name'] is String) call.addName(function['name']! as String);
    final arguments = function['arguments'];
    if (arguments is String) {
      call.addArguments(arguments);
    } else if (arguments != null) {
      call.addArguments(jsonEncode(arguments));
    }
  }

  List<_ToolCall> _parseToolCalls(Object? raw) {
    if (raw is! List) return const <_ToolCall>[];
    return raw
        .whereType<Map>()
        .map((value) {
          final function = value['function'];
          final source = function is Map ? function : value;
          return _toolCallFromFunction(
            source,
            id: '${value['id'] ?? value['call_id'] ?? ''}',
            index: 0,
          );
        })
        .whereType<_ToolCall>()
        .toList();
  }

  Uri _endpoint(String configured, {bool models = false}) {
    final raw = configured.trim();
    if (raw.isEmpty) throw const FormatException('请先设置 API 地址');
    var uri = Uri.parse(raw);
    if (!uri.hasScheme || uri.host.isEmpty)
      throw const FormatException('API 地址无效');
    final local =
        uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '10.0.2.2';
    if (uri.scheme != 'https' && !(local && kDebugMode))
      throw const FormatException('非调试环境的 API 必须使用 HTTPS');
    final suffix = models ? '/models' : '/chat/completions';
    if (models && uri.path.endsWith('/chat/completions')) {
      uri = uri.replace(
        path:
            uri.path.substring(
              0,
              uri.path.length - '/chat/completions'.length,
            ) +
            '/models',
      );
    } else if (!models && uri.path.endsWith('/models')) {
      uri = uri.replace(
        path:
            uri.path.substring(0, uri.path.length - '/models'.length) +
            '/chat/completions',
      );
    } else if (!_isCompletionEndpoint(uri.path) &&
        !_isModelsEndpoint(uri.path)) {
      uri = uri.replace(
        path: '${uri.path.replaceAll(RegExp(r'/+$'), '')}$suffix',
      );
    }
    return uri;
  }

  bool _isCompletionEndpoint(String path) =>
      path.replaceAll(RegExp(r'/+$'), '').endsWith('/chat/completions');

  bool _isModelsEndpoint(String path) =>
      path.replaceAll(RegExp(r'/+$'), '').endsWith('/models');

  /// OpenAI-compatible gateways are not consistent about reasoning controls.
  /// Only send the documented GLM fields to Zhipu's official endpoint so an
  /// ordinary third-party profile cannot start failing because of an unknown
  /// request member.
  Map<String, Object?> _reasoningRequestFields({
    required Uri endpoint,
    required String model,
    required bool? enabled,
    String? effort,
  }) {
    if (enabled == null) return const <String, Object?>{};
    final host = endpoint.host.toLowerCase();
    final normalizedModel = model.trim().toLowerCase();
    final isOfficialZhipu =
        host == 'open.bigmodel.cn' || host.endsWith('.bigmodel.cn');
    if (!isOfficialZhipu || !normalizedModel.startsWith('glm-')) {
      return const <String, Object?>{};
    }
    final fields = <String, Object?>{
      'thinking': <String, Object?>{'type': enabled ? 'enabled' : 'disabled'},
    };
    // GLM-5.2 documents reasoning_effort. Older GLM endpoints may reject it,
    // so keep the compatibility boundary deliberately narrow.
    if (enabled && normalizedModel.startsWith('glm-5.2')) {
      final normalizedEffort = switch (effort?.trim().toLowerCase()) {
        'low' || 'medium' || 'high' || 'max' => effort!.trim().toLowerCase(),
        _ => 'max',
      };
      fields['reasoning_effort'] = normalizedEffort;
    }
    return fields;
  }

  Future<Map<String, String>> _headers(ApiProfile profile) async {
    const blocked = <String>{
      'host',
      'content-length',
      'connection',
      'transfer-encoding',
      'authorization',
      'proxy-authorization',
      'cookie',
    };
    final result = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
    };
    for (final entry in profile.customHeaders.entries) {
      final name = entry.key.trim();
      if (name.isEmpty ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name)) {
        throw FormatException('自定义请求头名称无效：${entry.key}');
      }
      if (blocked.contains(name.toLowerCase())) {
        throw FormatException('不允许自定义敏感请求头：$name');
      }
      if (entry.value.contains('\r') || entry.value.contains('\n')) {
        throw FormatException('自定义请求头值不能包含换行：$name');
      }
      result[name] = entry.value;
    }
    final key = await vault.readApiKey(profile.id);
    if (key != null && key.isNotEmpty) result['authorization'] = 'Bearer $key';
    return result;
  }

  String _safeError(int status, String body) {
    try {
      final value = jsonDecode(body);
      final message = value is Map && value['error'] is Map
          ? (value['error'] as Map)['message']
          : null;
      if (message is String && message.isNotEmpty)
        return 'API 请求失败 ($status)：$message';
    } on FormatException {
      // Do not expose arbitrary HTML or server dumps to the UI.
    }
    return 'API 请求失败 ($status)';
  }
}

class _RoundResult {
  const _RoundResult({
    required this.text,
    required this.reasoning,
    required this.usage,
    required this.toolCalls,
    this.finishReason = '',
  });
  final String text;
  final String reasoning;
  final Map<String, Object?> usage;
  final List<_ToolCall> toolCalls;
  final String finishReason;
}

class ChatCompletionPart {
  const ChatCompletionPart({
    required this.type,
    this.content,
    this.metadata = const <String, Object?>{},
  });

  final String type;
  final String? content;
  final Map<String, Object?> metadata;

  MessagePartInput toInput() =>
      MessagePartInput(type: type, content: content, metadata: metadata);
}

class ChatCompletionResult {
  const ChatCompletionResult({
    required this.text,
    required this.parts,
    required this.usage,
    required this.elapsed,
  });

  final String text;
  final List<ChatCompletionPart> parts;
  final Map<String, Object?> usage;
  final Duration elapsed;
}

class _ToolCall {
  const _ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
  final String id;
  final String name;
  final String arguments;
  Map<String, Object?> toApi() => <String, Object?>{
    'id': id,
    'type': 'function',
    'function': <String, String>{'name': name, 'arguments': arguments},
  };
}

class _MutableToolCall {
  String id = '';
  final List<String> _nameFragments = <String>[];
  final List<String> _argumentFragments = <String>[];

  String get currentName => _mergeProviderFragments(_nameFragments);
  String get currentArguments => _mergeProviderFragments(_argumentFragments);

  void addName(String value) {
    if (value.isNotEmpty) _nameFragments.add(value);
  }

  void addArguments(String value) {
    if (value.isNotEmpty) _argumentFragments.add(value);
  }

  _ToolCall freeze(int index) => _ToolCall(
    id: id.isEmpty ? 'tool-$index' : id,
    name: _mergeProviderFragments(_nameFragments),
    arguments: _mergeProviderFragments(_argumentFragments),
  );
}

String _mergeProviderFragments(List<String> fragments) {
  if (fragments.isEmpty) return '';
  var cumulative = fragments.first;
  var isCumulative = true;
  for (final fragment in fragments.skip(1)) {
    if (fragment.startsWith(cumulative)) {
      cumulative = fragment;
    } else if (!cumulative.startsWith(fragment)) {
      isCumulative = false;
      break;
    }
  }
  return isCumulative ? cumulative : fragments.join();
}
