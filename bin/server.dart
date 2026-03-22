import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ── Models ──────────────────────────────────────────────────────────────────

class Player {
  final WebSocketChannel channel;
  String? choice; // rock, scissors, paper
  Player(this.channel);
}

class Room {
  final String code;
  Player? player1;
  Player? player2;
  int round = 1;
  bool get isFull => player1 != null && player2 != null;
  bool get bothChosen => player1?.choice != null && player2?.choice != null;
  Room(this.code);
}

// ── Game Logic ──────────────────────────────────────────────────────────────

String resolveRound(String move1, String move2) {
  if (move1 == move2) return 'draw';
  if ((move1 == 'rock' && move2 == 'scissors') ||
      (move1 == 'scissors' && move2 == 'paper') ||
      (move1 == 'paper' && move2 == 'rock')) {
    return 'player1';
  }
  return 'player2';
}

// ── Server State ────────────────────────────────────────────────────────────

final Map<String, Room> rooms = {};
final _random = Random();

String generateCode() {
  String code;
  do {
    code = (1000 + _random.nextInt(9000)).toString();
  } while (rooms.containsKey(code));
  return code;
}

void removeRoom(String code) {
  rooms.remove(code);
  print('[room $code] removed (${rooms.length} active)');
}

Room? findRoomByChannel(WebSocketChannel ch) {
  for (final room in rooms.values) {
    if (room.player1?.channel == ch || room.player2?.channel == ch) {
      return room;
    }
  }
  return null;
}

bool isPlayer1(Room room, WebSocketChannel ch) =>
    room.player1?.channel == ch;

void send(WebSocketChannel ch, Map<String, dynamic> data) {
  try {
    ch.sink.add(jsonEncode(data));
  } catch (_) {}
}

// ── Message Handling ────────────────────────────────────────────────────────

void handleMessage(WebSocketChannel ch, String raw) {
  late Map<String, dynamic> msg;
  try {
    msg = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    send(ch, {'type': 'error', 'message': 'invalid json'});
    return;
  }

  final type = msg['type'] as String?;

  switch (type) {
    case 'create':
      _handleCreate(ch);
    case 'join':
      _handleJoin(ch, msg['code'] as String?);
    case 'move':
      _handleMove(ch, msg['choice'] as String?);
    case 'leave':
      _handleLeave(ch);
    default:
      send(ch, {'type': 'error', 'message': 'unknown type: $type'});
  }
}

void _handleCreate(WebSocketChannel ch) {
  final existing = findRoomByChannel(ch);
  if (existing != null) _handleLeave(ch);

  final code = generateCode();
  final room = Room(code);
  room.player1 = Player(ch);
  rooms[code] = room;

  print('[room $code] created (${rooms.length} active)');
  send(ch, {'type': 'created', 'code': code});
}

void _handleJoin(WebSocketChannel ch, String? code) {
  if (code == null) {
    send(ch, {'type': 'error', 'message': 'code required'});
    return;
  }

  final room = rooms[code];
  if (room == null) {
    send(ch, {'type': 'error', 'message': 'room_not_found'});
    return;
  }
  if (room.isFull) {
    send(ch, {'type': 'error', 'message': 'room_full'});
    return;
  }

  room.player2 = Player(ch);
  print('[room $code] player2 joined');

  send(ch, {'type': 'joined', 'code': code});

  // Notify both: game starts
  send(room.player1!.channel, {
    'type': 'start',
    'role': 'player1',
    'round': room.round,
  });
  send(room.player2!.channel, {
    'type': 'start',
    'role': 'player2',
    'round': room.round,
  });
}

void _handleMove(WebSocketChannel ch, String? choice) {
  if (choice == null || !['rock', 'scissors', 'paper'].contains(choice)) {
    send(ch, {'type': 'error', 'message': 'invalid choice'});
    return;
  }

  final room = findRoomByChannel(ch);
  if (room == null || !room.isFull) {
    send(ch, {'type': 'error', 'message': 'not in active game'});
    return;
  }

  final isP1 = isPlayer1(room, ch);
  final player = isP1 ? room.player1! : room.player2!;
  final opponent = isP1 ? room.player2! : room.player1!;

  if (player.choice != null) {
    send(ch, {'type': 'error', 'message': 'already chosen'});
    return;
  }

  player.choice = choice;
  send(opponent.channel, {'type': 'opponent_ready'});

  if (room.bothChosen) {
    final winner = resolveRound(room.player1!.choice!, room.player2!.choice!);

    final result = {
      'type': 'result',
      'player1_choice': room.player1!.choice,
      'player2_choice': room.player2!.choice,
      'winner': winner,
      'round': room.round,
    };

    send(room.player1!.channel, result);
    send(room.player2!.channel, result);

    print('[room ${room.code}] round ${room.round}: '
        '${room.player1!.choice} vs ${room.player2!.choice} -> $winner');

    room.player1!.choice = null;
    room.player2!.choice = null;
    room.round++;
  }
}

void _handleLeave(WebSocketChannel ch) {
  final room = findRoomByChannel(ch);
  if (room == null) return;

  final code = room.code;
  final isP1 = isPlayer1(room, ch);

  final opponent = isP1 ? room.player2 : room.player1;
  if (opponent != null) {
    send(opponent.channel, {'type': 'opponent_left'});
  }

  removeRoom(code);
}

void handleDisconnect(WebSocketChannel ch) {
  _handleLeave(ch);
}

// ── Server Entry Point ──────────────────────────────────────────────────────

Future<void> main() async {
  final port = int.fromEnvironment('PORT', defaultValue: 8080);

  final handler = webSocketHandler((WebSocketChannel channel, String? protocol) {
    print('[+] client connected');

    channel.stream.listen(
      (data) {
        if (data is String) {
          handleMessage(channel, data);
        }
      },
      onDone: () {
        print('[-] client disconnected');
        handleDisconnect(channel);
      },
      onError: (e) {
        print('[!] error: $e');
        handleDisconnect(channel);
      },
    );
  });

  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  print('KNB server running on ws://${server.address.host}:${server.port}');
}
