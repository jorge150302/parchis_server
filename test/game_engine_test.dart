import 'dart:math';

import 'package:parchis_server/game_engine.dart';
import 'package:parchis_server/logic/board_generator.dart';
import 'package:parchis_server/logic/board_presets.dart';
import 'package:parchis_server/models/board_action.dart';
import 'package:parchis_server/models/player.dart';
import 'package:test/test.dart';

GameEngine _engine({
  int players = 2,
  int cells = 20,
  List<int> actionPositions = const [],
  List<BoardAction> actions = const [],
  Random? random,
}) {
  return GameEngine(
    board: generateBoard(actionPositions, actions, totalCells: cells),
    players: [for (var i = 0; i < players; i++) Player(id: 'p$i', name: 'P$i')],
    random: random,
  );
}

void main() {
  group('rollDice', () {
    test('always returns 1..6 and records lastDiceValue', () {
      final engine = _engine(random: Random(42));
      for (var i = 0; i < 500; i++) {
        final v = engine.rollDice();
        expect(v, inInclusiveRange(1, 6));
        expect(engine.lastDiceValue, v);
      }
    });
  });

  group('nextTurn', () {
    test('advances to the next unfinished player', () {
      final engine = _engine(players: 3);
      for (final t in engine.players[1].tokens) {
        t.isFinished = true;
      }
      engine.nextTurn();
      expect(engine.currentPlayer.id, 'p2');
      expect(engine.phase, GamePhase.rolling);
    });

    test('ends the game when one active player remains', () {
      final engine = _engine();
      for (final t in engine.players[0].tokens) {
        t.isFinished = true;
      }
      engine.finishedPlayers.add(engine.players[0]);
      engine.nextTurn();
      expect(engine.phase, GamePhase.finished);
      expect(engine.finishedPlayers.map((p) => p.id), ['p0', 'p1']);
    });

    test("resets the outgoing player's consecutive sixes", () {
      final engine = _engine();
      engine.registerSix(engine.currentPlayer, 6);
      engine.registerSix(engine.currentPlayer, 6);
      final first = engine.currentPlayer;
      engine.nextTurn();
      expect(first.consecutiveSixes, 0);
    });
  });

  group('three sixes', () {
    test('counts consecutive sixes and resets on another value', () {
      final engine = _engine();
      final p = engine.currentPlayer;
      engine
        ..registerSix(p, 6)
        ..registerSix(p, 6);
      expect(engine.reachedThreeSixes(p), isFalse);
      engine.registerSix(p, 6);
      expect(engine.reachedThreeSixes(p), isTrue);
      engine.registerSix(p, 3);
      expect(p.consecutiveSixes, 0);
    });

    test('penalty sends unfinished tokens home and clears extra turns', () {
      final engine = _engine();
      final p = engine.currentPlayer;
      p.tokens[0].position = 7;
      p.tokens[1].isFinished = true;
      p.extraTurns = 2;
      engine.penaltyThreeSixes(p);
      expect(p.tokens[0].position, 0);
      expect(p.tokens[1].isFinished, isTrue);
      expect(p.extraTurns, 0);
    });
  });

  group('canMove', () {
    test('requires an exact roll to reach the goal', () {
      final engine = _engine();
      final t = engine.currentPlayer.tokens[0]..position = 17;
      expect(engine.canMove(t, 3), isTrue);
      expect(engine.canMove(t, 4), isFalse);
    });

    test('cannot pass or land on a bridge', () {
      final engine = _engine();
      for (final t in engine.players[1].tokens) {
        t.position = 5;
      }
      final t = engine.currentPlayer.tokens[0]..position = 3;
      expect(engine.canMove(t, 1), isTrue);
      expect(engine.canMove(t, 2), isFalse);
      expect(engine.canMove(t, 4), isFalse);
    });

    test('finished tokens never move', () {
      final engine = _engine();
      final t = engine.currentPlayer.tokens[0]..isFinished = true;
      expect(engine.canMove(t, 1), isFalse);
    });
  });

  group('stepForward', () {
    test('finishing every token records the player as finished', () {
      final engine = _engine(cells: 10);
      final p = engine.currentPlayer;
      p.tokens[1].isFinished = true;
      p.tokens[0].position = 9;
      expect(engine.stepForward(p.tokens[0]), isTrue);
      expect(p.tokens[0].isFinished, isTrue);
      expect(p.tokens[0].position, -1);
      expect(engine.finishedPlayers, [p]);
    });
  });

  group('applyCellAction', () {
    GameEngine withAction(BoardAction action) =>
        _engine(actionPositions: [5], actions: [action]);

    test('goToStart sends the token home', () {
      final engine = withAction(BoardAction.goToStart());
      final t = engine.currentPlayer.tokens[0]..position = 5;
      expect(engine.applyCellAction(engine.currentPlayer, t), isTrue);
      expect(t.position, 0);
    });

    test('moveTo jumps to the target cell', () {
      final engine = withAction(BoardAction.moveTo(12));
      final t = engine.currentPlayer.tokens[0]..position = 5;
      engine.applyCellAction(engine.currentPlayer, t);
      expect(t.position, 12);
    });

    test('moveTo past the goal finishes the token', () {
      final engine = withAction(BoardAction.moveTo(99));
      final t = engine.currentPlayer.tokens[0]..position = 5;
      engine.applyCellAction(engine.currentPlayer, t);
      expect(t.isFinished, isTrue);
    });

    test('skipTurn and rollAgain update the player counters', () {
      var engine = withAction(BoardAction.skipTurn());
      var t = engine.currentPlayer.tokens[0]..position = 5;
      engine.applyCellAction(engine.currentPlayer, t);
      expect(engine.currentPlayer.mustSkipTurn, isTrue);

      engine = withAction(BoardAction.rollAgain());
      t = engine.currentPlayer.tokens[0]..position = 5;
      engine.applyCellAction(engine.currentPlayer, t);
      expect(engine.currentPlayer.extraTurns, 1);
    });

    test('finished or home tokens are ignored', () {
      final engine = withAction(BoardAction.goToStart());
      final t = engine.currentPlayer.tokens[0];
      expect(engine.applyCellAction(engine.currentPlayer, t), isFalse);
    });
  });

  group('resolveCollisions', () {
    test('captures every rival token on the cell, +1 turn each', () {
      final engine = _engine(players: 3);
      final mover = engine.currentPlayer.tokens[0]..position = 8;
      engine.players[1].tokens[0].position = 8;
      engine.players[2].tokens[0].position = 8;
      final captured = engine.resolveCollisions(mover);
      expect(captured.map((p) => p.id), ['p1', 'p2']);
      expect(engine.players[1].tokens[0].position, 0);
      expect(engine.players[2].tokens[0].position, 0);
      expect(engine.currentPlayer.extraTurns, 2);
    });

    test('ignores own tokens, home tokens and empty cells', () {
      final engine = _engine();
      final mover = engine.currentPlayer.tokens[0]..position = 8;
      engine.currentPlayer.tokens[1].position = 8;
      engine.players[1].tokens[0].position = 9;
      expect(engine.resolveCollisions(mover), isEmpty);
      expect(engine.currentPlayer.tokens[1].position, 8);

      mover.position = 0;
      engine.players[1].tokens[0].position = 0;
      expect(engine.resolveCollisions(mover), isEmpty);
    });
  });

  group('classic preset', () {
    test('every action position fits the 100-cell board', () {
      expect(classicActionPositions.length, classicActions.length);
      final board = generateBoard(classicActionPositions, classicActions,
          totalCells: 100);
      for (final pos in classicActionPositions) {
        expect(board.getCell(pos).hasAction, isTrue, reason: 'cell $pos');
      }
      for (final a in classicActions) {
        if (a.targetNumber != null) {
          expect(a.targetNumber, inInclusiveRange(1, 100));
        }
      }
    });
  });
}
