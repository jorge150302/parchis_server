// Contenido para parchis_server/lib/models/player.dart

class Player {
  final String id;
  final String name;

  int position;
  int skippedTurns;
  int consecutiveSixes;
  int extraTurns;
  bool isFinished;
  bool isMoving;
  int stepsMoved;
  bool isAI;

  Player({
    required this.id,
    required this.name,
    this.position = 0,
    this.skippedTurns = 0,
    this.consecutiveSixes = 0,
    this.extraTurns = 0,
    this.isFinished = false,
    this.isMoving = false,
    this.stepsMoved = 0,
    this.isAI = false,
  });

  void resetToStart() {
    position = 0;
    skippedTurns = 0;
    consecutiveSixes = 0;
    extraTurns = 0;
    isFinished = false;
    isMoving = false;
    stepsMoved = 0;
  }

  void moveBy(int steps) {
    position += steps;
    stepsMoved += steps;
  }

  void addSkip(int turns) {
    skippedTurns += turns;
  }

  void finish() {
    isFinished = true;
  }

  bool get mustSkipTurn => skippedTurns > 0;

  void consumeSkip() {
    if (skippedTurns > 0) skippedTurns--;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'position': position,
        'isFinished': isFinished,
        'isAI': isAI,
        'skippedTurns': skippedTurns,
        'extraTurns': extraTurns,
        'consecutiveSixes': consecutiveSixes,
      };
}
