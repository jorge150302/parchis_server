// Contenido actualizado para parchis_server/lib/models/player.dart

class Token {

  Token({
    required this.id,
    this.position = 0,
    this.isFinished = false,
  });
  final int id;
  int position;
  bool isFinished;

  void reset() {
    position = 0;
    isFinished = false;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'position': position,
        'isFinished': isFinished,
      };
}

class Player {

  Player({
    required this.id,
    required this.name,
    int numTokens = 2,
    this.skippedTurns = 0,
    this.consecutiveSixes = 0,
    this.extraTurns = 0,
    this.isAI = false,
    this.isAutoPlaying = false,
    this.isConnected = true,
    this.lastDiceValue = 0,
    this.level = 1,
    this.avatarType = 'google',
    this.avatarIconId,
  }) : tokens = List.generate(numTokens, (i) => Token(id: i));
  final String id;
  final String name;

  List<Token> tokens;
  int skippedTurns;
  int consecutiveSixes;
  int extraTurns;
  bool isAI;
  bool isAutoPlaying;
  bool isConnected;
  int lastDiceValue;
  int level;
  String avatarType;
  String? avatarIconId;

  void resetToStart() {
    for (final token in tokens) {
      if (!token.isFinished) {
        token.reset();
      }
    }
    skippedTurns = 0;
    consecutiveSixes = 0;
    extraTurns = 0;
    lastDiceValue = 1;
  }

  bool get isFinished => tokens.every((t) => t.isFinished);

  void addSkip(int turns) {
    skippedTurns += turns;
  }

  bool get mustSkipTurn => skippedTurns > 0;

  void consumeSkip() {
    if (skippedTurns > 0) skippedTurns--;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tokens': tokens.map((t) => t.toJson()).toList(),
        'isFinished': isFinished,
        'isAI': isAI,
        'isAutoPlaying': isAutoPlaying,
        'isConnected': isConnected,
        'skippedTurns': skippedTurns,
        'extraTurns': extraTurns,
        'consecutiveSixes': consecutiveSixes,
        'lastDiceValue': lastDiceValue,
        'level': level,
        'avatarType': avatarType,
        'avatarIconId': avatarIconId,
      };
}
