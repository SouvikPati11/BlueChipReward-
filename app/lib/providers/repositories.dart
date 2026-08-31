import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/admin_repository.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/earn_repository.dart';
import '../data/repositories/user_repository.dart';
import '../data/repositories/wallet_repository.dart';

final authRepositoryProvider = Provider((_) => AuthRepository());
final userRepositoryProvider = Provider((_) => UserRepository());
final earnRepositoryProvider = Provider((_) => EarnRepository());
final walletRepositoryProvider = Provider((_) => WalletRepository());
final adminRepositoryProvider = Provider((_) => AdminRepository());
