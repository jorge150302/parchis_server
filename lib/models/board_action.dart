// Contenido para parchis_server/lib/models/board_action.dart

enum BoardActionType { goToStart, moveTo, skipTurn, rollAgain }

class BoardAction {
  final BoardActionType type;
  final int? targetNumber; // solo para moveTo

  BoardAction.goToStart()
      : type = BoardActionType.goToStart,
        targetNumber = null;

  BoardAction.moveTo(int target)
      : type = BoardActionType.moveTo,
        targetNumber = target;

  BoardAction.skipTurn()
      : type = BoardActionType.skipTurn,
        targetNumber = null;

  BoardAction.rollAgain()
      : type = BoardActionType.rollAgain,
        targetNumber = null;
}
