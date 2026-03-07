// Contenido para parchis_server/lib/game_engine.dart

import 'dart:math';

// Copiaremos estos modelos a continuación
import 'models/board.dart';
import 'models/player.dart';
import 'models/board_action.dart';

enum GamePhase {
  idle,
  rolling,
  moving,
  finished,
}

class GameEngine {
  final Board board;
  final List<Player> players;
  final Random _random = Random();
  final List<Player> finishedPlayers = [];

  int _currentPlayerIndex = 0;
  GamePhase phase = GamePhase.idle;

  GameEngine({
    required this.board,
    required this.players,
  });

  Player get currentPlayer => players[_currentPlayerIndex];

  int rollDice() => _random.nextInt(6) + 1;

  void nextTurn() {
    if (players.where((p) => !p.isFinished).length <= 1) {
      phase = GamePhase.finished;
      final lastPlayer = players.firstWhere((p) => !p.isFinished);
      if (!finishedPlayers.contains(lastPlayer)) {
        finishedPlayers.add(lastPlayer);
      }
      return;
    }

    do {
      _currentPlayerIndex = (_currentPlayerIndex + 1) % players.length;
    } while (currentPlayer.isFinished);
  }

  void registerSix(Player player, int diceValue) {
    if (diceValue == 6) {
      player.consecutiveSixes++;
    } else {
      player.consecutiveSixes = 0;
    }
  }

  bool reachedThreeSixes(Player player) => player.consecutiveSixes >= 3;

  bool penaltyThreeSixes(Player player) {
    player.resetToStart();
    // En el servidor, manejaremos los eventos de forma diferente
    return true;
  }

  bool canMove(Player player, int steps) {
    return player.position + steps <= board.finalPosition;
  }

  void stepForward(Player player) {
    if (player.position < board.finalPosition) {
      player.moveBy(1);
      if (player.position == board.finalPosition) {
        player.finish();
        if (!finishedPlayers.contains(player)) {
          finishedPlayers.add(player);
        }
      }
    }
  }

  void stopMoving(Player player) {
    player.isMoving = false;
  }

  bool applyCellAction(Player player) {
    final cell = board.getCell(player.position);
    final action = cell.action;
    bool sentHome = false;

    if (action != null) {
      switch (action.type) {
        case BoardActionType.goToStart:
          player.resetToStart();
          sentHome = true;
          break;
        case BoardActionType.moveTo:
          if (action.targetNumber != null) {
            player.position = action.targetNumber!;
          }
          break;
        case BoardActionType.skipTurn:
          player.addSkip(1);
          break;
        case BoardActionType.rollAgain:
          player.extraTurns++;
          break;
      }
    }
    return sentHome;
  }

  bool resolveCollisions(Player player) {
    if (player.isFinished) return false;

    final playersInCell = players.where((p) => p != player && p.position == player.position).toList();
    bool sentHome = false;

    for (final otherPlayer in playersInCell) {
      otherPlayer.resetToStart();
      sentHome = true;
    }
    return sentHome;
  }
}