import 'dart:convert';
import 'dart:async';

import 'package:claudechat/domain/entities.dart';
import 'package:claudechat/services/api_client.dart';
import 'package:claudechat/services/secure_vault.dart';
import 'package:claudechat/services/settings_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues(<String, String>{});

  test('captures ordered thought/content parts and usage', () async {
    final api = ApiClient(
      SecureVault(),
      client: _QueueClient(<String>[
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{
                'reasoning_content': '先整理问题',
                'content': '这是答案',
              },
            },
          ],
          'usage': <String, Object?>{
            'prompt_tokens': 12,
            'completion_tokens': 4,
          },
        }),
      ]),
    );

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => '{}',
      stream: false,
    );

    expect(result.text, '这是答案');
    expect(result.parts.map((part) => part.type), <String>[
      'thought',
      'content',
    ]);
    expect(result.parts.first.content, '先整理问题');
    expect(result.usage['prompt_tokens'], 12);
  });

  test('sends documented thinking controls to official GLM-5.2 only', () async {
    final client = _QueueClient(<String>[
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': '完成'},
          },
        ],
      }),
    ]);
    final api = ApiClient(SecureVault(), client: client);

    await api.chatWithTools(
      profile: const ApiProfile(
        id: 'zhipu',
        name: '智谱',
        endpoint: 'https://open.bigmodel.cn/api/paas/v4',
      ),
      model: 'glm-5.2',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => '{}',
      stream: false,
      thinkingEnabled: true,
      reasoningEffort: 'max',
    );

    final payload = jsonDecode(client.requests.single) as Map<String, Object?>;
    expect(payload['thinking'], <String, Object?>{'type': 'enabled'});
    expect(payload['reasoning_effort'], 'max');
  });

  test(
    'can explicitly restart thinking without replaying old reasoning',
    () async {
      final client = _QueueClient(<String>[
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{
                'reasoning_content': '这一轮重新思考',
                'content': '继续回答',
              },
            },
          ],
        }),
      ]);
      final api = ApiClient(SecureVault(), client: client);

      final result = await api.chatWithTools(
        profile: const ApiProfile(
          id: 'zhipu',
          name: '智谱',
          endpoint: 'https://open.bigmodel.cn/api/paas/v4',
        ),
        model: 'glm-5.2',
        messages: <ChatMessage>[_message],
        systemPrompt: '',
        tools: const <Map<String, Object?>>[],
        executeTool: (_, _, _) async => '{}',
        stream: false,
        thinkingEnabled: true,
        reasoningEffort: 'max',
        clearHistoricalReasoning: true,
      );

      final payload =
          jsonDecode(client.requests.single) as Map<String, Object?>;
      expect(payload['thinking'], <String, Object?>{
        'type': 'enabled',
        'clear_thinking': true,
      });
      final history = payload['messages']! as List<Object?>;
      expect(
        history.whereType<Map>().any(
          (message) => message.containsKey('reasoning_content'),
        ),
        isFalse,
      );
      expect(result.parts.first.content, '这一轮重新思考');
    },
  );

  test('does not send provider-specific thinking fields to gateways', () async {
    final client = _QueueClient(<String>[
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': '完成'},
          },
        ],
      }),
    ]);
    final api = ApiClient(SecureVault(), client: client);

    await api.chatWithTools(
      profile: _profile,
      model: 'glm-5.2',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => '{}',
      stream: false,
      thinkingEnabled: true,
      reasoningEffort: 'max',
    );

    final payload = jsonDecode(client.requests.single) as Map<String, Object?>;
    expect(payload, isNot(contains('thinking')));
    expect(payload, isNot(contains('reasoning_effort')));
  });

  test('captures compatible reasoning aliases outside message', () async {
    final api = ApiClient(
      SecureVault(),
      client: _QueueClient(<String>[
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'analysisContent': '先检查兼容接口',
              'message': <String, Object?>{'content': '兼容完成'},
            },
          ],
        }),
      ]),
    );

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => '{}',
      stream: false,
    );

    expect(result.text, '兼容完成');
    expect(result.parts.map((part) => part.type), <String>[
      'thought',
      'content',
    ]);
    expect(result.parts.first.content, '先检查兼容接口');
  });

  test('rehydrates historical tool calls and receipts in message order', () {
    final assistant = ChatMessage(
      id: 'assistant-history',
      conversationId: 'conversation',
      sequence: 2,
      role: 'assistant',
      content: '我先搜索。找到一条。',
      createdAt: DateTime.utc(2026),
    );
    final parts = <MessagePart>[
      MessagePart(
        id: 'part-1',
        messageId: assistant.id,
        sequence: 1,
        type: 'content',
        content: '我先搜索。',
        createdAt: DateTime.utc(2026),
      ),
      MessagePart(
        id: 'part-2',
        messageId: assistant.id,
        sequence: 2,
        type: 'status',
        metadataJson: jsonEncode(<String, Object?>{
          'callId': 'call-history-1',
          'name': 'search_files',
          'status': 'tool_completed',
        }),
        createdAt: DateTime.utc(2026),
      ),
      MessagePart(
        id: 'part-3',
        messageId: assistant.id,
        sequence: 3,
        type: 'tool',
        content: '{"matches":[{"id":"file-1"}]}',
        metadataJson: jsonEncode(<String, Object?>{
          'callId': 'call-history-1',
          'name': 'search_files',
          'arguments': <String, Object?>{'query': '测试'},
          'status': 'success',
        }),
        createdAt: DateTime.utc(2026),
      ),
      MessagePart(
        id: 'part-4',
        messageId: assistant.id,
        sequence: 4,
        type: 'content',
        content: '找到一条。',
        createdAt: DateTime.utc(2026),
      ),
    ];

    final history = buildToolAwareApiMessages(
      messages: <ChatMessage>[_message, assistant],
      messagePartsByMessage: <String, List<MessagePart>>{assistant.id: parts},
    );

    expect(history.map((item) => item['role']), <String>[
      'user',
      'assistant',
      'tool',
      'assistant',
    ]);
    final call = ((history[1]['tool_calls'] as List).single as Map);
    expect(call['id'], 'call-history-1');
    expect((call['function'] as Map)['name'], 'search_files');
    expect(history[2]['tool_call_id'], 'call-history-1');
    expect(history[2]['content'], contains('file-1'));
    expect(history[3]['content'], '找到一条。');
  });

  test(
    'sends restored tool history and emits redacted-ready diagnostics',
    () async {
      final client = _QueueClient(<String>[
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{'content': '继续。'},
              'finish_reason': 'stop',
            },
          ],
        }),
      ]);
      final assistant = ChatMessage(
        id: 'assistant-history',
        conversationId: 'conversation',
        sequence: 2,
        role: 'assistant',
        content: '',
        createdAt: DateTime.utc(2026),
      );
      final toolPart = MessagePart(
        id: 'tool-part',
        messageId: assistant.id,
        sequence: 1,
        type: 'tool',
        content: '{"matches":[]}',
        metadataJson: jsonEncode(<String, Object?>{
          'callId': 'old-call',
          'name': 'search_files',
          'arguments': <String, Object?>{'query': '旧窗口'},
          'status': 'success',
        }),
        createdAt: DateTime.utc(2026),
      );
      final events = <Map<String, Object?>>[];
      final api = ApiClient(SecureVault(), client: client);

      await api.chatWithTools(
        profile: _profile,
        model: 'test-model',
        messages: <ChatMessage>[_message, assistant],
        messagePartsByMessage: <String, List<MessagePart>>{
          assistant.id: <MessagePart>[toolPart],
        },
        systemPrompt: '',
        tools: const <Map<String, Object?>>[
          <String, Object?>{
            'type': 'function',
            'function': <String, Object?>{'name': 'search_files'},
          },
        ],
        executeTool: (_, _, _) async => '{}',
        stream: false,
        diagnosticContext: const <String, Object?>{'requestId': 'request-1'},
        onDiagnostic: events.add,
      );

      final payload = jsonDecode(client.requests.single) as Map;
      final apiMessages = payload['messages'] as List;
      expect(
        apiMessages.any((item) => (item as Map)['tool_calls'] != null),
        isTrue,
      );
      expect(
        apiMessages.any((item) => (item as Map)['role'] == 'tool'),
        isTrue,
      );
      expect(
        events
            .where((event) => event['event'] == 'chat_request_started')
            .single['restoredHistoricalToolCalls'],
        1,
      );
      expect(
        events
            .where((event) => event['event'] == 'model_round_completed')
            .single['toolCallCount'],
        0,
      );
    },
  );

  test(
    'extracts nonstandard usage containers returned by compatible APIs',
    () async {
      final api = ApiClient(
        SecureVault(),
        client: _QueueClient(<String>[
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{'content': 'ok'},
              },
            ],
            'usageMetadata': <String, Object?>{
              'promptTokenCount': 200,
              'cachedContentTokenCount': 50,
            },
          }),
        ]),
      );

      final result = await api.chatWithTools(
        profile: _profile,
        model: 'test-model',
        messages: <ChatMessage>[_message],
        systemPrompt: '',
        tools: const <Map<String, Object?>>[],
        executeTool: (_, _, _) async => '{}',
        stream: false,
      );

      expect(result.usage['promptTokenCount'], 200);
      expect(result.usage['cachedContentTokenCount'], 50);
    },
  );

  test('requests streamed usage and reads nested response usage', () async {
    final client = _QueueClient(<String>[
      '${_sse(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'delta': <String, Object?>{'content': 'ok'},
          },
        ],
      })}${_sse(<String, Object?>{
        'choices': const <Object?>[],
        'response': <String, Object?>{
          'usage': <String, Object?>{
            'prompt_tokens': 100,
            'prompt_tokens_details': <String, Object?>{'cached_tokens': 80},
          },
        },
      })}data: [DONE]\n\n',
    ]);
    final api = ApiClient(SecureVault(), client: client);

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => '{}',
    );

    final payload = jsonDecode(client.requests.single) as Map;
    expect((payload['stream_options'] as Map)['include_usage'], isTrue);
    expect(result.usage['prompt_tokens'], 100);
    expect((result.usage['prompt_tokens_details'] as Map)['cached_tokens'], 80);
  });

  test('retries streaming without stream_options for strict relays', () async {
    final client = _RejectStreamOptionsClient();
    final api = ApiClient(SecureVault(), client: client);

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => '{}',
    );

    expect(result.text, '兼容成功');
    expect(client.requests, hasLength(2));
    expect(client.requests.first, contains('stream_options'));
    expect(client.requests.last, isNot(contains('stream_options')));
  });

  test('captures a tool result between model rounds', () async {
    final api = ApiClient(
      SecureVault(),
      client: _QueueClient(<String>[
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{
                'content': '',
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'id': 'call-1',
                    'function': <String, Object?>{
                      'name': 'get_time',
                      'arguments': '{}',
                    },
                  },
                ],
              },
            },
          ],
          'usage': <String, Object?>{'prompt_tokens': 5},
        }),
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{'content': '现在是中午。'},
            },
          ],
          'usage': <String, Object?>{'completion_tokens': 3},
        }),
      ]),
    );
    var calls = 0;

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[
        <String, Object?>{
          'type': 'function',
          'function': <String, Object?>{'name': 'get_time'},
        },
      ],
      executeTool: (_, name, arguments) async {
        calls++;
        return jsonEncode(<String, Object?>{'time': '12:00'});
      },
      stream: false,
    );

    expect(calls, 1);
    expect(result.parts.map((part) => part.type), <String>['tool', 'content']);
    expect(result.parts.first.metadata['status'], 'success');
    expect(result.parts.first.metadata['callId'], 'call-1');
    expect(result.parts.first.metadata['name'], 'get_time');
    expect(result.text, '现在是中午。');
    expect(result.usage['prompt_tokens'], 5);
    expect(result.usage['completion_tokens'], 3);
    expect(result.usage['_rounds'], isA<List<Object?>>());
    expect((result.usage['_rounds'] as List<Object?>), hasLength(2));
  });

  test('emits each completed round in thought-body-tool order', () async {
    final api = ApiClient(
      SecureVault(),
      client: _QueueClient(<String>[
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{
                'reasoning_content': '先想第一步',
                'content': '先说明一下。',
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'id': 'call-file',
                    'function': <String, Object?>{
                      'name': 'search_files',
                      'arguments': '{"query":"迁移"}',
                    },
                  },
                ],
              },
            },
          ],
        }),
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{
                'reasoning_content': '结合文件继续想',
                'content': '这是最终正文。',
              },
            },
          ],
        }),
      ]),
    );
    final events = <ChatCompletionPart>[];

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[
        <String, Object?>{
          'type': 'function',
          'function': <String, Object?>{'name': 'search_files'},
        },
      ],
      executeTool: (_, _, _) async => '{"matches":[]}',
      onToolEvent: events.add,
      stream: false,
    );

    expect(result.parts.map((part) => part.type), <String>[
      'thought',
      'content',
      'tool',
      'thought',
      'content',
    ]);
    expect(events.map((part) => part.type), <String>[
      'thought',
      'content',
      'tool',
      'thought',
      'content',
    ]);
  });

  test(
    'streams text immediately and stops at DONE without waiting for close',
    () async {
      final client = _OpenStreamClient();
      final api = ApiClient(SecureVault(), client: client);
      final firstChunk = Completer<void>();
      final chunks = <String>[];

      final completion = api.chatWithTools(
        profile: _profile,
        model: 'test-model',
        messages: <ChatMessage>[_message],
        systemPrompt: '',
        tools: const <Map<String, Object?>>[],
        executeTool: (_, _, _) async => '{}',
        onText: (value) {
          chunks.add(value);
          if (!firstChunk.isCompleted) firstChunk.complete();
        },
      );

      client.add('data: {"choices":[{"delta":{"content":"第一段"}}]}\n\n');
      await firstChunk.future.timeout(const Duration(seconds: 1));
      expect(chunks, <String>['第一段']);

      client.add('data: {"choices":[{"delta":{"content":"第二段"}}]}\n\n');
      client.add('data: [DONE]\n\n');
      final result = await completion.timeout(const Duration(seconds: 1));
      expect(chunks, <String>['第一段', '第二段']);
      expect(result.text, '第一段第二段');
      await client.finish();
    },
  );

  test('appends chat path to versioned compatible base endpoints', () async {
    final client = _RecordingQueueClient(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'ok'},
          },
        ],
      }),
    );
    final api = ApiClient(SecureVault(), client: client);
    await api.chatWithTools(
      profile: const ApiProfile(
        id: 'glm',
        name: 'GLM',
        endpoint: 'https://open.bigmodel.cn/api/paas/v4',
      ),
      model: 'glm-test',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => '{}',
      stream: false,
    );
    expect(
      client.lastUri,
      Uri.parse('https://open.bigmodel.cn/api/paas/v4/chat/completions'),
    );
  });

  test('verified file receipt reaches the next model round', () async {
    final client = _QueueClient(<String>[
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': '',
              'tool_calls': <Object?>[
                <String, Object?>{
                  'id': 'call-create',
                  'function': <String, Object?>{
                    'name': 'create_file',
                    'arguments': '{"name":"demo.html","content":""}',
                  },
                },
              ],
            },
          },
        ],
      }),
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': '文件已保存，文件ID是 file-1。'},
          },
        ],
      }),
    ]);
    final api = ApiClient(SecureVault(), client: client);

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{
          'id': 'file-1',
          'versionId': 'version-1',
          'name': 'demo.html',
          'action': 'created',
          'verified': true,
          'sha256': 'abc123',
          'byteSize': 0,
        },
      }),
      stream: false,
    );

    expect(result.text, '文件已保存，文件ID是 file-1。');
    expect(result.parts.first.metadata['status'], 'success');
    expect(result.parts.first.metadata['name'], 'create_file');
    expect(client.index, 2);
    expect(client.requests.last, contains('file-1'));
    expect(client.requests.last, contains('version-1'));
  });

  test('rejects nominal file success without integrity proof', () async {
    final client = _QueueClient(<String>[
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': '',
              'tool_calls': <Object?>[
                <String, Object?>{
                  'id': 'call-create',
                  'function': <String, Object?>{
                    'name': 'create_file',
                    'arguments': '{"name":"demo.html","content":"x"}',
                  },
                },
              ],
            },
          },
        ],
      }),
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': '文件写入未确认。'},
          },
        ],
      }),
    ]);
    final api = ApiClient(SecureVault(), client: client);

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{'name': 'demo.html', 'action': 'created'},
      }),
      stream: false,
    );

    expect(result.text, '文件写入未确认。');
    expect(result.parts.first.metadata['status'], 'error');
    expect(result.parts.first.content, contains('完整性证明'));
    expect(client.index, 2);
  });

  test(
    'accepts a verified workspace file receipt without a version id',
    () async {
      final client = _QueueClient(<String>[
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{
                'content': '',
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'id': 'call-workspace-create',
                    'function': <String, Object?>{
                      'name': 'create_workspace_file',
                      'arguments': '{"name":"src/app.js","content":"ok"}',
                    },
                  },
                ],
              },
            },
          ],
        }),
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{'content': '工作区文件已保存。'},
            },
          ],
        }),
      ]);
      final api = ApiClient(SecureVault(), client: client);

      final result = await api.chatWithTools(
        profile: _profile,
        model: 'test-model',
        messages: <ChatMessage>[_message],
        systemPrompt: '',
        tools: const <Map<String, Object?>>[],
        executeTool: (_, _, _) async => jsonEncode(<String, Object?>{
          'ok': true,
          'result': <String, Object?>{
            'id': 'workspace-file-1',
            'name': 'src/app.js',
            'sha256': 'abc123',
            'verified': true,
          },
        }),
        stream: false,
      );

      expect(result.text, '工作区文件已保存。');
      expect(result.parts.first.metadata['status'], 'success');
      expect(result.parts.first.metadata['name'], 'create_workspace_file');
      expect(client.requests.last, contains('workspace-file-1'));
    },
  );

  test('rejects an unverified workspace file receipt', () async {
    final client = _QueueClient(<String>[
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': '',
              'tool_calls': <Object?>[
                <String, Object?>{
                  'id': 'call-workspace-edit',
                  'function': <String, Object?>{
                    'name': 'edit_workspace_file',
                    'arguments': '{"name":"app.js","content":"changed"}',
                  },
                },
              ],
            },
          },
        ],
      }),
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': '保存没有得到确认。'},
          },
        ],
      }),
    ]);
    final api = ApiClient(SecureVault(), client: client);

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{'id': 'workspace-file-1', 'name': 'app.js'},
      }),
      stream: false,
    );

    expect(result.text, '保存没有得到确认。');
    expect(result.parts.first.metadata['status'], 'error');
    expect(result.parts.first.content, contains('完整性证明'));
  });

  test('omits max_tokens when the model limit is unset', () async {
    final client = _QueueClient(<String>[
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'ok'},
          },
        ],
      }),
    ]);
    final api = ApiClient(SecureVault(), client: client);

    await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => '{}',
      stream: false,
      maxTokens: null,
    );

    final request = jsonDecode(client.requests.single) as Map;
    expect(request.containsKey('max_tokens'), isFalse);
  });

  test(
    'accepts cumulative streamed tool arguments without duplicating them',
    () async {
      final client = _QueueClient(<String>[
        '${_sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    'id': 'call-create',
                    'function': <String, Object?>{'name': 'create_file', 'arguments': r'{"name":"demo.html"'},
                  },
                ],
              },
            },
          ],
        })}${_sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    'id': 'call-create',
                    'function': <String, Object?>{'name': 'create_file', 'arguments': r'{"name":"demo.html","content":"ok"}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        })}data: [DONE]\n\n',
        '${_sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{'content': '已创建。'},
              'finish_reason': 'stop',
            },
          ],
        })}data: [DONE]\n\n',
      ]);
      final api = ApiClient(SecureVault(), client: client);
      Map<String, Object?>? received;

      final result = await api.chatWithTools(
        profile: _profile,
        model: 'test-model',
        messages: <ChatMessage>[_message],
        systemPrompt: '',
        tools: const <Map<String, Object?>>[
          <String, Object?>{
            'type': 'function',
            'function': <String, Object?>{'name': 'create_file'},
          },
        ],
        executeTool: (_, name, arguments) async {
          expect(name, 'create_file');
          received = arguments;
          return jsonEncode(<String, Object?>{
            'ok': true,
            'result': <String, Object?>{
              'id': 'file-1',
              'versionId': 'version-1',
              'verified': true,
              'sha256': 'abc123',
            },
          });
        },
      );

      expect(received, <String, Object?>{'name': 'demo.html', 'content': 'ok'});
      expect(result.text, '已创建。');
    },
  );

  test(
    'reports streamed tool preparation and verified execution progress',
    () async {
      final client = _QueueClient(<String>[
        '${_sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    'id': 'call-create',
                    'function': <String, Object?>{'name': 'create_file', 'arguments': r'{"name":"demo.html","content":"ok"}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        })}data: [DONE]\n\n',
        '${_sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{'content': '已创建。'},
              'finish_reason': 'stop',
            },
          ],
        })}data: [DONE]\n\n',
      ]);
      final progress = <ChatCompletionPart?>[];
      var activities = 0;
      final api = ApiClient(SecureVault(), client: client);

      await api.chatWithTools(
        profile: _profile,
        model: 'test-model',
        messages: <ChatMessage>[_message],
        systemPrompt: '',
        tools: const <Map<String, Object?>>[
          <String, Object?>{
            'type': 'function',
            'function': <String, Object?>{'name': 'create_file'},
          },
        ],
        executeTool: (_, _, _) async => jsonEncode(<String, Object?>{
          'ok': true,
          'result': <String, Object?>{
            'id': 'file-1',
            'versionId': 'version-1',
            'verified': true,
            'sha256': 'abc123',
          },
        }),
        onToolProgress: progress.add,
        onActivity: () => activities++,
      );

      expect(
        progress.whereType<ChatCompletionPart>().map(
          (part) => part.metadata['status'],
        ),
        containsAllInOrder(<String>['preparing', 'running']),
      );
      final running = progress.whereType<ChatCompletionPart>().firstWhere(
        (part) => part.metadata['status'] == 'running',
      );
      expect((running.metadata['arguments'] as Map)['name'], 'demo.html');
      expect(progress.last, isNull);
      expect(activities, greaterThan(2));
    },
  );

  test('exposes growing streamed file content as read-only progress', () async {
    final longChunk = List<String>.filled(160, 'a').join();
    final firstRound = StringBuffer()
      ..write(
        _sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    'id': 'call-live',
                    'function': <String, Object?>{
                      'name': 'create_workspace_file',
                      'arguments': r'{"name":"live.html","content":"',
                    },
                  },
                ],
              },
            },
          ],
        }),
      )
      ..write(
        _sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    'function': <String, Object?>{'arguments': longChunk},
                  },
                ],
              },
            },
          ],
        }),
      )
      ..write(
        _sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    'function': <String, Object?>{'arguments': r'"}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        }),
      )
      ..write('data: [DONE]\n\n');
    final client = _QueueClient(<String>[
      firstRound.toString(),
      '${_sse(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'delta': <String, Object?>{'content': '完成。'},
            'finish_reason': 'stop',
          },
        ],
      })}data: [DONE]\n\n',
    ]);
    final progress = <ChatCompletionPart?>[];

    await ApiClient(SecureVault(), client: client).chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{
          'id': 'workspace-file-1',
          'verified': true,
          'sha256': 'abc123',
        },
      }),
      onToolProgress: progress.add,
    );

    final partial = progress.whereType<ChatCompletionPart>().firstWhere(
      (part) =>
          part.metadata['partialArguments'] == true &&
          ((part.metadata['arguments'] as Map)['content'] as String?)?.contains(
                'aaaa',
              ) ==
              true,
    );
    expect((partial.metadata['arguments'] as Map)['name'], 'live.html');
  });

  test('stream idle timeout renews while chunks keep arriving', () async {
    final api = ApiClient(
      SecureVault(),
      client: _TimedStreamClient(),
      responseIdleTimeout: const Duration(milliseconds: 50),
    );

    final result = await api.chatWithTools(
      profile: _profile,
      model: 'test-model',
      messages: <ChatMessage>[_message],
      systemPrompt: '',
      tools: const <Map<String, Object?>>[],
      executeTool: (_, _, _) async => '{}',
    );

    expect(result.text, '持续传输');
  });

  test(
    'stream idle timeout stays alive while a file tool is streaming',
    () async {
      final diagnostics = <Map<String, Object?>>[];
      final progress = <ChatCompletionPart?>[];
      final api = ApiClient(
        SecureVault(),
        client: _FileToolPauseClient(),
        responseIdleTimeout: const Duration(milliseconds: 25),
        toolProgressMinDuration: Duration.zero,
      );

      final result = await api.chatWithTools(
        profile: _profile,
        model: 'test-model',
        messages: <ChatMessage>[_message],
        systemPrompt: '',
        tools: const <Map<String, Object?>>[],
        executeTool: (_, name, arguments) async => jsonEncode(<String, Object?>{
          'ok': true,
          'tool': name,
          'verified': true,
          'name': arguments['name'],
        }),
        onToolProgress: progress.add,
        onDiagnostic: diagnostics.add,
      );

      expect(result.text, '文件已保存');
      expect(
        progress.whereType<ChatCompletionPart>().any(
          (part) =>
              part.metadata['name'] == 'create_workspace_file' &&
              part.metadata['status'] == 'preparing',
        ),
        isTrue,
      );
      expect(
        diagnostics.any(
          (event) => event['event'] == 'response_idle_extended_for_file_tool',
        ),
        isTrue,
      );
    },
  );

  test(
    'retries a truncated streamed tool call without executing partial JSON',
    () async {
      final client = _QueueClient(<String>[
        '${_sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    'id': 'call-create',
                    'function': <String, Object?>{'name': 'create_file', 'arguments': r'{"name":"large.html","content":"partial'},
                  },
                ],
              },
              'finish_reason': 'length',
            },
          ],
        })}data: [DONE]\n\n',
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'id': 'call-create',
                    'function': <String, Object?>{
                      'name': 'create_file',
                      'arguments':
                          r'{"name":"large.html","content":"complete"}',
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        }),
        '${_sse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{'content': '保存成功。'},
              'finish_reason': 'stop',
            },
          ],
        })}data: [DONE]\n\n',
      ]);
      final api = ApiClient(SecureVault(), client: client);
      var executions = 0;

      final result = await api.chatWithTools(
        profile: _profile,
        model: 'test-model',
        messages: <ChatMessage>[_message],
        systemPrompt: '',
        tools: const <Map<String, Object?>>[
          <String, Object?>{
            'type': 'function',
            'function': <String, Object?>{'name': 'create_file'},
          },
        ],
        executeTool: (_, _, arguments) async {
          executions++;
          expect(arguments['content'], 'complete');
          return jsonEncode(<String, Object?>{
            'ok': true,
            'result': <String, Object?>{
              'id': 'file-1',
              'versionId': 'version-1',
              'verified': true,
              'sha256': 'abc123',
            },
          });
        },
      );

      expect(executions, 1);
      expect(result.text, '保存成功。');
      expect(client.index, 3);
    },
  );
}

String _sse(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';

const _profile = ApiProfile(
  id: 'profile',
  name: 'test',
  endpoint: 'https://api.example.test/v1',
);

final _message = ChatMessage(
  id: 'message',
  conversationId: 'conversation',
  sequence: 1,
  role: 'user',
  content: '你好',
  createdAt: DateTime.utc(2026),
);

class _QueueClient extends http.BaseClient {
  _QueueClient(this.bodies);

  final List<String> bodies;
  final List<String> requests = <String>[];
  int index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) requests.add(request.body);
    final body = bodies[index++];
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
    );
  }
}

class _OpenStreamClient extends http.BaseClient {
  final StreamController<List<int>> _controller = StreamController<List<int>>();

  void add(String value) => _controller.add(utf8.encode(value));

  Future<void> finish() => _controller.close();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(_controller.stream, 200);
}

class _RecordingQueueClient extends http.BaseClient {
  _RecordingQueueClient(this.body);

  final String body;
  Uri? lastUri;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastUri = request.url;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
    );
  }
}

class _TimedStreamClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(_chunks(), 200);

  Stream<List<int>> _chunks() async* {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    yield utf8.encode('data: {"choices":[{"delta":{"content":"持续"}}]}\n\n');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    yield utf8.encode('data: {"choices":[{"delta":{"content":"传输"}}]}\n\n');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    yield utf8.encode('data: [DONE]\n\n');
  }
}

class _FileToolPauseClient extends http.BaseClient {
  var _requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _requestCount++;
    if (_requestCount == 1) {
      return http.StreamedResponse(_toolChunks(), 200);
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(
          '${_sse(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'delta': <String, Object?>{'content': '文件已保存'},
                'finish_reason': 'stop',
              },
            ],
          })}data: [DONE]\n\n',
        ),
      ),
      200,
    );
  }

  Stream<List<int>> _toolChunks() async* {
    yield utf8.encode(
      _sse(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'delta': <String, Object?>{
              'tool_calls': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'id': 'call-file-pause',
                  'function': <String, Object?>{
                    'name': 'create_workspace_file',
                    'arguments': r'{"name":"large.py","content":"',
                  },
                },
              ],
            },
          },
        ],
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    yield utf8.encode(
      '${_sse(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'delta': <String, Object?>{
              'tool_calls': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'function': <String, Object?>{'arguments': r'print(42)"}'},
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      })}data: [DONE]\n\n',
    );
  }
}

class _RejectStreamOptionsClient extends http.BaseClient {
  final List<String> requests = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    requests.add(body);
    if (body.contains('stream_options')) {
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode('{"error":{"message":"unknown stream_options"}}'),
        ),
        400,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(
          '${_sse(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'delta': <String, Object?>{'content': '兼容成功'},
              },
            ],
          })}data: [DONE]\n\n',
        ),
      ),
      200,
    );
  }
}
