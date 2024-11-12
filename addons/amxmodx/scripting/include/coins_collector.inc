#if defined _coins_collector_included
	#endinput
#endif
#define _coins_collector_included

#define cc_var_dying_state var_iuser2
#define cc_var_owner var_iuser3
#define cc_var_killer var_owner // do not change, var_owner required at least for EF_OWNER_VISIBILITY logic

/**
 * Called before a coin is spawned.
 *
 * @note			ET_STOP
 *
 * @return      PLUGIN_HANDLED to block the coin from being spawned.
 *              		PLUGIN_CONTINUE to allow spawn.
*/
forward CC_SpawnCoinPre(pPlayer);

/**
 * Called after a coin has been spawned.
 *
 * @note			ET_IGNORE
 *
 * @noreturn
*/
forward CC_SpawnCoinPost(pPlayer, pCoinEntity);