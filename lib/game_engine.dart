// Contenido para parchis_server/lib/game_engine.dart

import 'dart:math';

import 'models/board.dart';
import 'models/player.dart';
import 'models/board_action.dart';

enum GamePhase {
  idle,
  rolling,
  choosingToken,
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
  int lastDiceValue = 0;

  GameEngine({
    required this.board,
    required this.players,
  });

  Player get currentPlayer => players[_currentPlayerIndex];

  int rollDice() {
    lastDiceValue = _random.nextInt(6) + 1;
    return lastDiceValue;
  }

  void nextTurn() {
    final remainingPlayers = players.where((p) => !p.isFinished).length;
    if (remainingPlayers <= 1) {
      phase = GamePhase.finished;
      for (final p in players) {
        if (!p.isFinished && !finishedPlayers.contains(p)) {
          finishedPlayers.add(p);
        }
      }
      return;
    }

    do {
      _currentPlayerIndex = (_currentPlayerIndex + 1) % players.length;
    } while (currentPlayer.isFinished);
    
    phase = GamePhase.rolling;
  }

  void registerSix(Player player, int diceValue) {
    if (diceValue == 6) {
      player.consecutiveSixes++;
    } else {
      player.consecutiveSixes = 0;
    }
  }

  bool reachedThreeSixes(Player player) => player.consecutiveSixes >= 3;

  void penaltyThreeSixes(Player player) {
    player.resetToStart();
  }

  /// Verifica si una casilla tiene un puente.
  /// En la zona común bloquea a todos. En la zona privada (> 68) solo al dueño.
  bool isBridge(int position, Player movingPlayer) {
    if (position <= 0 || position >= board.finalPosition) return false;
    
    for (final player in players) {
      final tokensAtPos = player.tokens.where((t) => !t.isFinished && t.position == position).length;
      if (tokensAtPos >= 2) {
        // REGLA: Pasillo de Meta (Zona Privada). 
        // Si la posición es mayor a 68, solo bloquea si el puente es del propio jugador.
        if (position > 68) {
          if (player.id == movingPlayer.id) return true;
        } else {
          // Zona común: cualquier puente bloquea a cualquiera.
          return true;
        }
      }
    }
    return false;
  }

  bool canMove(Token token, int steps) {
    if (token.isFinished) return false;
    
    // REGLA: Si la ficha está en casa (0), solo puede salir si el dado es un 5.
    // DESACTIVADO TEMPORALMENTE: Para pruebas del tablero corto.
    // if (token.position == 0 && steps != 5) return false;

    final targetPos = token.position + steps;
    
    // REGLA: Tiro exacto para entrar a la meta.
    if (targetPos > board.finalPosition) return false;

    // REGLA: Puentes (Bloqueos). No se puede saltar ni caer en un puente.
    for (int i = 1; i <= steps; i++) {
      int checkPos = token.position + i;
      if (isBridge(checkPos, currentPlayer)) return false;
    }

    return true;
  }

  bool canMoveAnyToken(Player player, int steps) {
    return player.tokens.any((token) => canMove(token, steps));
  }

  /// Mueve un paso y asegura que el estado isFinished se marque correctamente.
  bool stepForward(Token token) {
    if (token.position < board.finalPosition) {
      token.position++;
      if (token.position == board.finalPosition) {
        token.isFinished = true;
        if (currentPlayer.isFinished) {
          if (!finishedPlayers.contains(currentPlayer)) {
            finishedPlayers.add(currentPlayer);
          }
        }
        return true;
      }
    }
    return false;
  }

  bool applyCellAction(Player player, Token token) {
    final cell = board.getCell(token.position);
    final action = cell.action;
    bool sentHome = false;

    if (action != null) {
      switch (action.type) {
        case BoardActionType.goToStart:
          token.reset();
          sentHome = true;
          break;
        case BoardActionType.moveTo:
          if (action.targetNumber != null) {
            token.position = action.targetNumber!;
            if (token.position >= board.finalPosition) {
              token.position = board.finalPosition;
              token.isFinished = true;
              if (player.isFinished && !finishedPlayers.contains(player)) {
                finishedPlayers.add(player);
              }
            }
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

  bool resolveCollisions(Token token) {
    if (token.isFinished) return false;

    bool sentHome = false;
    for (final otherPlayer in players) {
      // REGLA: No hay "Fuego Amigo". No capturamos fichas propias.
      if (otherPlayer.id == currentPlayer.id) continue;

      for (final otherToken in otherPlayer.tokens) {
        if (otherToken.isFinished) continue;
        if (otherToken.position == 0) continue;

        if (otherToken.position == token.position) {
          otherToken.reset();
          sentHome = true;
        }
      }
    }
    return sentHome;
  }
}
