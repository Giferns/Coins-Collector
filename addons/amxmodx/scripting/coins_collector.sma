/*
	1.0.0f (07.11.2024 by mx?!):
		* Ревизия и переработка кода базовой версии "Raise_the_coin 1.0.4" от "Baton4ik48"
		* Изменено название на "Coins Collector"
		* Улучшение логики
		* Устранение ошибок
		* Улучшена конфигурабельность
			* В конфиг выведено больше кваров изначальных настроек
			* В конфиг добавлены новые настройки
		* Добавлен словарь "data/coins_collector.txt"
		* Заложено API "scripting/include/coins_collector.inc"
		* Упразднён вариант работы через nVault
	1.0.1f (12.11.2024 by mx?!):
		* Добавлен квар "сс_coin_killer_mode", позволяющий скрыть чужие монеты (убийца видит и поднимает только монеты из собственных жертв)
		* Исправлен баг с отсутствием выпадения монет после первого выпадения монеты
*/

#include <amxmodx>
#include <fakemeta>
#include <reapi>
#include <sqlx>
#include <coins_collector>

// Плагин основан на плагине "Raise_the_coin 1.0.4" автора "Baton4ik48" https://dev-cs.ru/resources/991/
new PLUGIN_NAME[] = "Coins Collector";
new PLUGIN_VERSION[] = "1.0.1f";
new PLUGIN_AUTHOR[] = "Baton4ik48 + mx?!";

// НАСТРОЙКИ НАЧАЛО ---------------->

// Режим отладки. В рабочей версии должен быть закомментирован.
//#define DEBUG

// Конфиг в "amxmodx/configs"
new const CONFIG_FILE[] = "coins_collector.cfg";

// Лог ошибок в "amxmodx/logs"
stock const SQL_ERROR_LOG[] = "coins_collector_sql_errors.log";

// Кастомный класснейм энтити
new const ENT_CLASSNAME[] = "coins_collector";

// Автозагрузка обоих sql-модулей. При желании, можно отключить ненужный.
#pragma reqlib sqlite
#pragma reqlib mysql
#if !defined AMXMODX_NOAUTOLOAD
	#pragma loadlib sqlite
	#pragma loadlib mysql
#endif

// <---------------- НАСТРОЙКИ КОНЕЦ

#pragma semicolon 1

// [1] AES Fork 0.5.9.1: https://dev-cs.ru/resources/362/
native aes_set_player_exp(player,Float:exp,bool:no_forward = false,bool:force = false);
native aes_set_player_bonus(player,bonus,bool:force = false);
native Float:aes_get_player_exp(player);
native aes_get_player_bonus(player);

// [2] Army Ranks Ultimate 20.06.06: https://fungun.net/shop/?p=show&id=1
native ar_set_user_addxp(id, addxp);
native ar_add_user_anew(admin, player, anew);

// [3] CMSStats Ranks 2.1.4: https://cs-games.club/index.php?resources/cmsstats-ranks.14/
native cmsranks_set_user_addxp(id, value);
native cmsranks_add_user_anew(id, value);

const TASKID__HUD_INFORMER = 1337;

enum {
	QUERY__CREATE_TABLE,
	QUERY__PRUNE_EXPIRED_ROWS,
	QUERY__LOAD_PLAYER,
	QUERY__SAVE_PLAYER,
	QUERY__INSERT_PLAYER
};

enum _:SQL_DATA_STRUCT {
	SQL_DATA__QUERY_TYPE,
	SQL_DATA__USERID
};

enum _:PCVAR_ENUM {
	PCVAR__ENT_GLOW,
	PCVAR__ENT_SIZE,
	PCVAR__TR_HUD,
	PCVAR__PICKUP_HUD,
	PCVAR__ENABLED
};

enum _:CVAR_ENUM {
	CVAR__SQL_HOST[64],
	CVAR__SQL_USER[64],
	CVAR__SQL_PWD[64],
	CVAR__SQL_DB[64],
	CVAR__SQL_TABLE[64],
	CVAR__SQL_DRIVER[32],
	CVAR__GLOW,
	Float:CVAR_F__ENT_LIFETIME,
	CVAR__DEATH_PENALTY_EXP,
	CVAR__COINS_TO_REWARD,
	CVAR__REWARD_EXP_AMT,
	CVAR__REWARD_BONUS_AMT,
	CVAR__REWARD_MONEY_AMT,
	CVAR__PRUNE_DAYS,
	CVAR__ENT_MODEL[96],
	CVAR__SND_PICKUP[96],
	Float:CVAR_F__ENT_GLOW[3],
	Float:CVAR_F__ENT_SIZE[6],
	Float:CVAR_F__ENT_FRAMERATE,
	CVAR__ENT_SEQUENCE,
	CVAR__RANK_SYSTEM_TYPE,
	CVAR__TR_HUD_R,
	CVAR__TR_HUD_G,
	CVAR__TR_HUD_B,
	Float:CVAR_F__TR_HUD_X,
	Float:CVAR_F__TR_HUD_Y,
	CVAR__TR_CHANNEL,
	CVAR__P_HUD_R,
	CVAR__P_HUD_G,
	CVAR__P_HUD_B,
	Float:CVAR_F__P_HUD_X,
	Float:CVAR_F__P_HUD_Y,
	Float:CVAR_F__P_HUD_DURATION,
	CVAR__P_CHANNEL,
	CVAR__NR_REMOVES_COINS,
	CVAR__MIN_PLAYERS,
	CVAR__COUNT_BOTS,
	CVAR__COIN_VALUE,
	Float:CVAR_F__COOLDOWN_GLOBAL,
	Float:CVAR_F__COOLDOWN_PERSONAL,
	CVAR__COIN_KILLER_MODE
};

new g_pCvar[PCVAR_ENUM];
new g_eCvar[CVAR_ENUM];
new g_iCoins[MAX_PLAYERS + 1];
new g_szQuery[512];
new Handle:g_hSqlTuple;
new g_eSqlData[SQL_DATA_STRUCT];
new bool:g_bPlayerDataLoaded[MAX_PLAYERS + 1];
new bool:g_bPluginEnded;
new bool:g_bSystemLoaded;
new HookChain:g_hKilled;
new g_fwdSpawnCoinPre;
new g_fwdSpawnCoinPost;
new Float:g_fLastSpawnCoinTime[MAX_PLAYERS + 1];

public plugin_precache() {
	register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
	register_dictionary("coins_collector.txt");

	// mx?!: Reg early to be compatible with my 'Presents' plugin (also register this hook in precache, but later, in plugin-presents.ini)
	// NOTE: this 'killed type hook' will not be triggered by death from bomb explosion
	g_hKilled = RegisterHookChain(RG_CSGameRules_PlayerKilled, "CSGameRules_PlayerKilled_Pre");
	DisableHookChain(g_hKilled);

	g_fwdSpawnCoinPre = CreateMultiForward("CC_SpawnCoinPre", ET_STOP, FP_CELL);
	g_fwdSpawnCoinPost = CreateMultiForward("CC_SpawnCoinPost", ET_IGNORE, FP_CELL, FP_CELL);

	RegCvars();

	new szPath[240];
	get_localinfo("amxx_configsdir", szPath, charsmax(szPath));
	server_cmd("exec %s/%s", szPath, CONFIG_FILE);
	server_exec();

	precache_model_safe(g_eCvar[CVAR__ENT_MODEL]);

	if(g_eCvar[CVAR__SND_PICKUP]) {
		precache_sound(g_eCvar[CVAR__SND_PICKUP]);
	}

	set_task(2.0, "task_InitSQL");
}

RegCvars() {
	bind_pcvar_string(create_cvar("cc_sql_host", "127.0.0.1"), g_eCvar[CVAR__SQL_HOST], charsmax(g_eCvar[CVAR__SQL_HOST]));
	bind_pcvar_string(create_cvar("cc_sql_user", "root"), g_eCvar[CVAR__SQL_USER], charsmax(g_eCvar[CVAR__SQL_USER]));
	bind_pcvar_string(create_cvar("cc_sql_pass", ""), g_eCvar[CVAR__SQL_PWD], charsmax(g_eCvar[CVAR__SQL_PWD]));
	bind_pcvar_string(create_cvar("cc_sql_db", "coins_collector"), g_eCvar[CVAR__SQL_DB], charsmax(g_eCvar[CVAR__SQL_DB]));
	bind_pcvar_string(create_cvar("cc_sql_table", "coins_collector"), g_eCvar[CVAR__SQL_TABLE], charsmax(g_eCvar[CVAR__SQL_TABLE]));
	bind_pcvar_string(create_cvar("cc_sql_driver", "mysql"), g_eCvar[CVAR__SQL_DRIVER], charsmax(g_eCvar[CVAR__SQL_DRIVER]));

	bind_pcvar_num(create_cvar("cc_rank_system_type", "1"), g_eCvar[CVAR__RANK_SYSTEM_TYPE]);

	g_pCvar[PCVAR__ENT_GLOW] = create_cvar("cc_ent_glow", "0 255 0");
	new szValue[32]; get_pcvar_string(g_pCvar[PCVAR__ENT_GLOW], szValue, charsmax(szValue));
	hook_CvarChange(g_pCvar[PCVAR__ENT_GLOW], "", szValue);
	hook_cvar_change(g_pCvar[PCVAR__ENT_GLOW], "hook_CvarChange");

	bind_pcvar_float(create_cvar("cc_ent_lifetime", "7.0"), g_eCvar[CVAR_F__ENT_LIFETIME]);
	bind_pcvar_num(create_cvar("cc_death_penalty_exp", "1"), g_eCvar[CVAR__DEATH_PENALTY_EXP]);
	bind_pcvar_num(create_cvar("cc_coins_to_reward", "10"), g_eCvar[CVAR__COINS_TO_REWARD]);
	bind_pcvar_num(create_cvar("cc_reward_exp_amt", "15"), g_eCvar[CVAR__REWARD_EXP_AMT]);
	bind_pcvar_num(create_cvar("cc_reward_bonus_amt", "2"), g_eCvar[CVAR__REWARD_BONUS_AMT]);
	bind_pcvar_num(create_cvar("cc_reward_money_amt", "5000"), g_eCvar[CVAR__REWARD_MONEY_AMT]);
	bind_pcvar_num(create_cvar("cc_prune_days", "5"), g_eCvar[CVAR__PRUNE_DAYS]);

	bind_pcvar_num(create_cvar("cc_newround_remove_coins", "1"), g_eCvar[CVAR__NR_REMOVES_COINS]);

	bind_pcvar_string(create_cvar("cc_ent_model", "models/exp.mdl"), g_eCvar[CVAR__ENT_MODEL], charsmax(g_eCvar[CVAR__ENT_MODEL]));

	g_pCvar[PCVAR__ENT_SIZE] = create_cvar("cc_ent_size", "-9.0 -7.0 0.0 9.0 7.0 6.0");
	get_pcvar_string(g_pCvar[PCVAR__ENT_SIZE], szValue, charsmax(szValue));
	hook_CvarChange(g_pCvar[PCVAR__ENT_SIZE], "", szValue);
	hook_cvar_change(g_pCvar[PCVAR__ENT_SIZE], "hook_CvarChange");

	bind_pcvar_float(create_cvar("cc_ent_framerate", "1.0"), g_eCvar[CVAR_F__ENT_FRAMERATE]);
	bind_pcvar_num(create_cvar("cc_ent_sequence", "2"), g_eCvar[CVAR__ENT_SEQUENCE]);

	bind_pcvar_string(create_cvar("cc_pickup_snd", "exp.wav"), g_eCvar[CVAR__SND_PICKUP], charsmax(g_eCvar[CVAR__SND_PICKUP]));

	g_pCvar[PCVAR__TR_HUD] = create_cvar("cc_tr_hud", "200 200 200 0.01 0.9 4");
	get_pcvar_string(g_pCvar[PCVAR__TR_HUD], szValue, charsmax(szValue));
	hook_CvarChange(g_pCvar[PCVAR__TR_HUD], "", szValue);
	hook_cvar_change(g_pCvar[PCVAR__TR_HUD], "hook_CvarChange");

	g_pCvar[PCVAR__PICKUP_HUD] = create_cvar("cc_pickup_hud", "0 255 -1.0 0.26 2.0 3");
	get_pcvar_string(g_pCvar[PCVAR__PICKUP_HUD], szValue, charsmax(szValue));
	hook_CvarChange(g_pCvar[PCVAR__PICKUP_HUD], "", szValue);
	hook_cvar_change(g_pCvar[PCVAR__PICKUP_HUD], "hook_CvarChange");

	g_pCvar[PCVAR__ENABLED] = create_cvar("cc_enabled", "1");

	bind_pcvar_num(create_cvar("cc_min_players", "8"), g_eCvar[CVAR__MIN_PLAYERS]);
	bind_pcvar_num(create_cvar("cc_count_bots", "0"), g_eCvar[CVAR__COUNT_BOTS]);
	bind_pcvar_num(create_cvar("cc_coin_value", "1"), g_eCvar[CVAR__COIN_VALUE]);
	bind_pcvar_float(create_cvar("cc_coin_cooldown_global", "0"), g_eCvar[CVAR_F__COOLDOWN_GLOBAL]);
	bind_pcvar_float(create_cvar("cc_coin_cooldown_personal", "15"), g_eCvar[CVAR_F__COOLDOWN_PERSONAL]);
	
	bind_pcvar_num(create_cvar("cc_coin_killer_mode", "0"), g_eCvar[CVAR__COIN_KILLER_MODE]);
}

public hook_CvarChange(pCvar, const szOldVal[], const szNewVal[]) {
	if(pCvar == g_pCvar[PCVAR__ENT_GLOW]) {
		new szColor[3][6];
		parse(szNewVal, szColor[0], charsmax(szColor[]), szColor[1], charsmax(szColor[]), szColor[2], charsmax(szColor[]));
		g_eCvar[CVAR_F__ENT_GLOW][0] = str_to_float(szColor[0]);
		g_eCvar[CVAR_F__ENT_GLOW][1] = str_to_float(szColor[1]);
		g_eCvar[CVAR_F__ENT_GLOW][2] = str_to_float(szColor[2]);
		return;
	}

	if(pCvar == g_pCvar[PCVAR__ENT_SIZE]) {
		new szSize[6][6];
		parse(szNewVal, szSize[0], charsmax(szSize[]), szSize[1], charsmax(szSize[]), szSize[2], charsmax(szSize[]), szSize[3], charsmax(szSize[]), szSize[4], charsmax(szSize[]), szSize[5], charsmax(szSize[]));
		for(new i; i < sizeof(szSize); i++) {
			g_eCvar[CVAR_F__ENT_SIZE][i] = str_to_float(szSize[i]);
		}
		return;
	}

	if(pCvar == g_pCvar[PCVAR__TR_HUD]) {
		new szColor[3][6], szPos[2][6], szChannel[6];
		parse(szNewVal, szColor[0], charsmax(szColor[]), szColor[1], charsmax(szColor[]), szColor[2], charsmax(szColor[]), szPos[0], charsmax(szPos[]), szPos[1], charsmax(szPos[]), szChannel, charsmax(szChannel));
		g_eCvar[CVAR__TR_HUD_R] = str_to_num(szColor[0]);
		g_eCvar[CVAR__TR_HUD_G] = str_to_num(szColor[1]);
		g_eCvar[CVAR__TR_HUD_B] = str_to_num(szColor[2]);
		g_eCvar[CVAR_F__TR_HUD_X] = str_to_float(szPos[0]);
		g_eCvar[CVAR_F__TR_HUD_Y] = str_to_float(szPos[1]);
		g_eCvar[CVAR__TR_CHANNEL] = str_to_num(szChannel);

		remove_task(TASKID__HUD_INFORMER);

		if(g_bSystemLoaded && get_pcvar_num(g_pCvar[PCVAR__ENABLED])) {
			SetHudInformerTask();
		}

		return;
	}

	if(pCvar == g_pCvar[PCVAR__PICKUP_HUD]) {
		new szColor[3][6], szPos[2][6], szDuration[6], szChannel[6];
		parse(szNewVal, szColor[0], charsmax(szColor[]), szColor[1], charsmax(szColor[]), szColor[2], charsmax(szColor[]), szPos[0], charsmax(szPos[]), szPos[1], charsmax(szPos[]), szDuration, charsmax(szDuration), szChannel, charsmax(szChannel));
		g_eCvar[CVAR__P_HUD_R] = str_to_num(szColor[0]);
		g_eCvar[CVAR__P_HUD_G] = str_to_num(szColor[1]);
		g_eCvar[CVAR__P_HUD_B] = str_to_num(szColor[2]);
		g_eCvar[CVAR_F__P_HUD_X] = str_to_float(szPos[0]);
		g_eCvar[CVAR_F__P_HUD_Y] = str_to_float(szPos[1]);
		g_eCvar[CVAR_F__P_HUD_DURATION] = str_to_float(szDuration);
		g_eCvar[CVAR__P_CHANNEL] = str_to_num(szChannel);
		return;
	}

	if(pCvar == g_pCvar[PCVAR__ENABLED]) {
		if(str_to_num(szNewVal)) {
			EnableHookChain(g_hKilled);
			remove_task(TASKID__HUD_INFORMER);
			SetHudInformerTask();
		}
		else {
			DisableHookChain(g_hKilled);
			remove_task(TASKID__HUD_INFORMER);
			RemoveAllCoins();
		}

		return;
	}
}

RemoveAllCoins() {
	new pEnt = MaxClients;

	while((pEnt = rg_find_ent_by_class(pEnt, ENT_CLASSNAME)) > 0) {
		set_entvar(pEnt, var_flags, FL_KILLME);
	}
}

SetHudInformerTask() {
	if(g_eCvar[CVAR__TR_HUD_R] || g_eCvar[CVAR__TR_HUD_G] || g_eCvar[CVAR__TR_HUD_B]) {
		set_task(1.0, "task_HudMsg", TASKID__HUD_INFORMER, .flags = "b");
	}
}

bool:CheckCoinSpawnCooldown(pPlayer, Float:fGameTime) {
	return (!g_fLastSpawnCoinTime[pPlayer] || fGameTime - g_fLastSpawnCoinTime[pPlayer] >= Float:g_eCvar[ pPlayer ? CVAR_F__COOLDOWN_PERSONAL : CVAR_F__COOLDOWN_GLOBAL ]);
}

public CSGameRules_PlayerKilled_Pre(pVictim, pKiller, pInflictor) {
	if(g_eCvar[CVAR__COIN_KILLER_MODE] && pVictim == pKiller) {
		return;
	}
	
	if(!CheckMinPlayers()) {
		return;
	}

	new Float:fGameTime = get_gametime();

	if(!CheckCoinSpawnCooldown(0, fGameTime) || !CheckCoinSpawnCooldown(pVictim, fGameTime)) {
		return;
	}

	if(CreateCoinEntity(pVictim, pKiller)) {
		g_fLastSpawnCoinTime[0] = fGameTime;
		g_fLastSpawnCoinTime[pVictim] = fGameTime;
		DeathPenaltyExp(pVictim);
	}
}

public CSGameRules_RestartRound_Pre() {
	if(g_eCvar[CVAR__NR_REMOVES_COINS]) {
		RemoveAllCoins();
	}
}

bool:CheckMinPlayers() {
	if(!g_eCvar[CVAR__MIN_PLAYERS]) {
		return true;
	}

	new pPlayers[MAX_PLAYERS], iPlCount, iInGame;
	get_players(pPlayers, iPlCount, g_eCvar[CVAR__COUNT_BOTS] ? "h" : "ch");

	for(new i; i < iPlCount; i++) {
		if(TEAM_SPECTATOR > get_member(pPlayers[i], m_iTeam) > TEAM_UNASSIGNED) {
			iInGame++;
		}
	}

	return (iInGame >= g_eCvar[CVAR__MIN_PLAYERS]);
}

DeathPenaltyExp(pPlayer) {
	if(!g_bPlayerDataLoaded[pPlayer] || g_eCvar[CVAR__DEATH_PENALTY_EXP] < 1) {
		return;
	}

	switch(g_eCvar[CVAR__RANK_SYSTEM_TYPE]) {
		case 1: aes_set_player_exp(pPlayer, aes_get_player_exp(pPlayer) + float( -g_eCvar[CVAR__DEATH_PENALTY_EXP] ));
		case 2: ar_set_user_addxp(pPlayer, -g_eCvar[CVAR__DEATH_PENALTY_EXP]);
		case 3: cmsranks_set_user_addxp(pPlayer, -g_eCvar[CVAR__DEATH_PENALTY_EXP]);
	}
}

bool:CreateCoinEntity(pVictim, pKiller) {
	new iRet;
	ExecuteForward(g_fwdSpawnCoinPre, iRet, pVictim);

	if(iRet) {
		return false;
	}

	new pEntity = rg_create_entity("info_target");

	if(pEntity < 1 || !is_entity(pEntity)) {
		return false;
	}

	new Float:fOrigin[3];
	get_entvar(pVictim, var_origin, fOrigin);

	new Float:fVelocity[3];
	fVelocity[0] = random_float(-200.0, 200.0);
	fVelocity[1] = random_float(-200.0, 200.0);
	fVelocity[2] = random_float(1.0, 200.0);

	new Float:fMins[3], Float:fMaxs[3];
	fMins[0] = g_eCvar[CVAR_F__ENT_SIZE][0];
	fMins[1] = g_eCvar[CVAR_F__ENT_SIZE][1];
	fMins[2] = g_eCvar[CVAR_F__ENT_SIZE][2];
	fMaxs[0] = g_eCvar[CVAR_F__ENT_SIZE][3];
	fMaxs[1] = g_eCvar[CVAR_F__ENT_SIZE][4];
	fMaxs[2] = g_eCvar[CVAR_F__ENT_SIZE][5];

	engfunc(EngFunc_SetOrigin, pEntity, fOrigin);
	engfunc(EngFunc_SetModel, pEntity, g_eCvar[CVAR__ENT_MODEL]);
	engfunc(EngFunc_SetSize, pEntity, fMins, fMaxs);
	set_entvar(pEntity, var_framerate, g_eCvar[CVAR_F__ENT_FRAMERATE]);
	set_entvar(pEntity, var_sequence, g_eCvar[CVAR__ENT_SEQUENCE]);

	set_entvar(pEntity, cc_var_killer, pKiller);
	set_entvar(pEntity, cc_var_owner, pVictim);
	
	if(g_eCvar[CVAR__COIN_KILLER_MODE]) {
		set_entvar(pEntity, var_effects, EF_OWNER_VISIBILITY);
	}

	set_entvar(pEntity, var_classname, ENT_CLASSNAME);
	set_entvar(pEntity, var_movetype, MOVETYPE_TOSS);
	set_entvar(pEntity, var_solid, SOLID_TRIGGER);
	set_entvar(pEntity, var_velocity, fVelocity);
	set_entvar(pEntity, var_nextthink, get_gametime() + g_eCvar[CVAR_F__ENT_LIFETIME]);

	if(g_eCvar[CVAR_F__ENT_GLOW][0] || g_eCvar[CVAR_F__ENT_GLOW][1] || g_eCvar[CVAR_F__ENT_GLOW][2]) {
		new Float:fColor[3];
		fColor[0] = g_eCvar[CVAR_F__ENT_GLOW][0];
		fColor[1] = g_eCvar[CVAR_F__ENT_GLOW][1];
		fColor[2] = g_eCvar[CVAR_F__ENT_GLOW][2];
		//set_entvar(pEntity, var_rendermode, kRenderGlow);
		set_entvar(pEntity, var_renderamt, 1.0);
		set_entvar(pEntity, var_rendercolor, fColor);
		set_entvar(pEntity, var_renderfx, kRenderFxGlowShell);
	}

	SetThink(pEntity, "OnThinkPre");
	SetTouch(pEntity, "OnTouchPre");

	ExecuteForward(g_fwdSpawnCoinPost, _, pVictim, pEntity);

	return true;
}

public OnThinkPre(pEntity) {
	if(!is_entity(pEntity)) {
		return;
	}

	new Float:fGameTime = get_gametime();

	if(!get_entvar(pEntity, cc_var_dying_state)) {
		set_entvar(pEntity, var_solid, SOLID_NOT);
		set_entvar(pEntity, cc_var_dying_state, 1);
		set_entvar(pEntity, var_renderfx, kRenderFxNone);
		set_entvar(pEntity, var_rendermode, kRenderTransTexture);
		set_entvar(pEntity, var_renderamt, 255.0);
		set_entvar(pEntity, var_nextthink, fGameTime + 0.1);
		return;
	}

	new Float:fRenderAmt = get_entvar(pEntity, var_renderamt);

	if(fRenderAmt > 10.0) {
		set_entvar(pEntity, var_renderamt, fRenderAmt - 4.0);
		set_entvar(pEntity, var_nextthink, fGameTime + 0.05);
		return;
	}

	set_entvar(pEntity, var_flags, FL_KILLME);
}

public OnTouchPre(pTouched, pToucher) {
	if(!is_entity(pTouched) || !is_user_connected(pToucher) || !g_bPlayerDataLoaded[pToucher]) {
		return;
	}

#if !defined DEBUG
	if(get_entvar(pTouched, cc_var_owner) == pToucher) {
		return;
	}
#endif

	if(g_eCvar[CVAR__COIN_KILLER_MODE] && get_entvar(pTouched, cc_var_killer) != pToucher) {
		return;
	}

	g_iCoins[pToucher] = min(g_eCvar[CVAR__COINS_TO_REWARD], g_iCoins[pToucher] + g_eCvar[CVAR__COIN_VALUE]);
	set_hudmessage(g_eCvar[CVAR__P_HUD_R], g_eCvar[CVAR__P_HUD_G], g_eCvar[CVAR__P_HUD_B], g_eCvar[CVAR_F__P_HUD_X], g_eCvar[CVAR_F__P_HUD_Y], 0, 0.0, g_eCvar[CVAR_F__P_HUD_DURATION], 0.1, 0.1, g_eCvar[CVAR__P_CHANNEL]);
	new szEnding[32]; GetEnding(g_eCvar[CVAR__COIN_VALUE], "CC__COIN_1", "CC__COIN_2", "CC__COIN_3", szEnding, charsmax(szEnding));
	show_hudmessage(pToucher, "%l", "CC__PICKUP_HUD", g_eCvar[CVAR__COIN_VALUE], szEnding);

	if(g_eCvar[CVAR__SND_PICKUP][0]) {
		rh_emit_sound2(pToucher, pToucher, CHAN_ITEM, g_eCvar[CVAR__SND_PICKUP], VOL_NORM, ATTN_NORM);
	}

	set_entvar(pTouched, var_flags, FL_KILLME);

	TryAddReward(pToucher);
}

TryAddReward(pPlayer) {
	if(g_iCoins[pPlayer] < g_eCvar[CVAR__COINS_TO_REWARD]) {
		return;
	}

	g_iCoins[pPlayer] = 0;

	SavePlayerData(pPlayer);

	new szMessage[189];

	if(LookupLangKey(szMessage, charsmax(szMessage), "CC__PICKUP_MSG", pPlayer)) {
		replace_string(szMessage, charsmax(szMessage), "[exp_val]", fmt("%i", g_eCvar[CVAR__REWARD_EXP_AMT]));
		replace_string(szMessage, charsmax(szMessage), "[bonus_val]", fmt("%i", g_eCvar[CVAR__REWARD_BONUS_AMT]));
		replace_string(szMessage, charsmax(szMessage), "[money_val]", fmt("%i", g_eCvar[CVAR__REWARD_MONEY_AMT]));
		new szString[32]; GetEnding(g_eCvar[CVAR__REWARD_EXP_AMT], "CC__EXP_1", "CC__EXP_2", "CC__EXP_3", szString, charsmax(szString));
		replace_string(szMessage, charsmax(szMessage), "[exp_string]", fmt("%L", pPlayer, szString));
		GetEnding(g_eCvar[CVAR__REWARD_BONUS_AMT], "CC__BONUS_1", "CC__BONUS_2", "CC__BONUS_3", szString, charsmax(szString));
		replace_string(szMessage, charsmax(szMessage), "[bonus_string]", fmt("%L", pPlayer, szString));
		GetEnding(g_eCvar[CVAR__REWARD_MONEY_AMT], "CC__MONEY_1", "CC__MONEY_2", "CC__MONEY_3", szString, charsmax(szString));
		replace_string(szMessage, charsmax(szMessage), "[money_string]", fmt("%L", pPlayer, szString));
		client_print_color(pPlayer, print_team_default, szMessage);
	}

	if(g_eCvar[CVAR__REWARD_MONEY_AMT] > 0) {
		rg_add_account(pPlayer, g_eCvar[CVAR__REWARD_MONEY_AMT]);
	}

	if(g_eCvar[CVAR__REWARD_EXP_AMT] > 0) {
		switch(g_eCvar[CVAR__RANK_SYSTEM_TYPE]) {
			case 1: aes_set_player_exp(pPlayer, aes_get_player_exp(pPlayer) + float( g_eCvar[CVAR__REWARD_EXP_AMT] ));
			case 2: ar_set_user_addxp(pPlayer, g_eCvar[CVAR__REWARD_EXP_AMT]);
			case 3: cmsranks_set_user_addxp(pPlayer, g_eCvar[CVAR__REWARD_EXP_AMT]);
		}
	}

	if(g_eCvar[CVAR__REWARD_BONUS_AMT] > 0) {
		switch(g_eCvar[CVAR__RANK_SYSTEM_TYPE]) {
			case 1: aes_set_player_bonus(pPlayer, aes_get_player_bonus(pPlayer) + g_eCvar[CVAR__REWARD_BONUS_AMT]);
			case 2: ar_add_user_anew(-1, pPlayer, g_eCvar[CVAR__REWARD_BONUS_AMT]);
			case 3: cmsranks_add_user_anew(pPlayer, g_eCvar[CVAR__REWARD_BONUS_AMT]);
		}
	}
}

public task_HudMsg() {
	set_hudmessage(g_eCvar[CVAR__TR_HUD_R], g_eCvar[CVAR__TR_HUD_G], g_eCvar[CVAR__TR_HUD_B], g_eCvar[CVAR_F__TR_HUD_X], g_eCvar[CVAR_F__TR_HUD_Y], 0, 0.0, 1.0, 0.1, 0.1, g_eCvar[CVAR__TR_CHANNEL]);

	new pPlayers[MAX_PLAYERS], iPlCount, pPlayer;
	get_players(pPlayers, iPlCount, "ach");

	for (new i; i < iPlCount; i++) {
		pPlayer = pPlayers[i];

		if(g_bPlayerDataLoaded[pPlayer]) {
			show_hudmessage(pPlayer, "%l", "CC__HUD_TIL_REWARD", g_iCoins[pPlayer], g_eCvar[CVAR__COINS_TO_REWARD]);
		}
	}
}

public client_putinserver(pPlayer) {
	if(is_user_bot(pPlayer) || is_user_hltv(pPlayer) || !g_bSystemLoaded) {
		return;
	}

	LoadPlayerData(pPlayer);
}

public client_disconnected(pPlayer) {
	if(!g_bPlayerDataLoaded[pPlayer]) {
		return;
	}

	g_bPlayerDataLoaded[pPlayer] = false;

	SavePlayerData(pPlayer);

	g_iCoins[pPlayer] = 0;
}

public task_InitSQL() {
	if(!SQL_SetAffinity(g_eCvar[CVAR__SQL_DRIVER])) {
		set_fail_state("Failed to set affinity to '%s' (module not loaded?)", g_eCvar[CVAR__SQL_DRIVER]);
		return;
	}

	g_hSqlTuple = SQL_MakeDbTuple(g_eCvar[CVAR__SQL_HOST], g_eCvar[CVAR__SQL_USER], g_eCvar[CVAR__SQL_PWD], g_eCvar[CVAR__SQL_DB]);

	formatex( g_szQuery, charsmax(g_szQuery),
		"CREATE TABLE IF NOT EXISTS `%s` (`steamid` varchar(32), `coin` INT(11), `time_join` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP);",

			g_eCvar[CVAR__SQL_TABLE]
	);

	MakeQuery(QUERY__CREATE_TABLE);
}

PruneExpiredRows() {
	if(g_eCvar[CVAR__PRUNE_DAYS] < 1) {
		return;
	}

	if(strcmp("mysql", g_eCvar[CVAR__SQL_DRIVER]) == 0) {
		formatex(g_szQuery, charsmax(g_szQuery), "DELETE FROM `%s` WHERE `time_join` < FROM_UNIXTIME(%i - (86400 * %i));", g_eCvar[CVAR__SQL_TABLE], get_systime(), g_eCvar[CVAR__PRUNE_DAYS]);
		MakeQuery(QUERY__PRUNE_EXPIRED_ROWS);
	}
	else if(strcmp("sqlite", g_eCvar[CVAR__SQL_DRIVER]) == 0) {
		formatex(g_szQuery, charsmax(g_szQuery), "DELETE FROM `%s` WHERE `time_join` < datetime('now','-%i day');", g_eCvar[CVAR__SQL_TABLE], g_eCvar[CVAR__PRUNE_DAYS]);
		MakeQuery(QUERY__PRUNE_EXPIRED_ROWS);
	}
}

LoadPlayerData(pPlayer) {
	new szAuthID[MAX_AUTHID_LENGTH];
	get_user_authid(pPlayer, szAuthID, charsmax(szAuthID));
	formatex(g_szQuery, charsmax(g_szQuery), "SELECT `coin` FROM `%s` WHERE (`steamid` = '%s')", g_eCvar[CVAR__SQL_TABLE], szAuthID);
	MakeQuery(QUERY__LOAD_PLAYER, pPlayer);
}

MakeQuery(iQueryType, pPlayer = 0) {
	g_eSqlData[SQL_DATA__QUERY_TYPE] = iQueryType;

	if(pPlayer) {
		g_eSqlData[SQL_DATA__USERID] = get_user_userid(pPlayer);
	}

	SQL_ThreadQuery(g_hSqlTuple, "SQL_Handler", g_szQuery, g_eSqlData, sizeof(g_eSqlData));
}

public SQL_Handler(iFailState, Handle:hQueryHandle, szError[], iErrorCode, eSqlData[], iDataSize, Float:fQueryTime) {
	if(g_bPluginEnded) {
		return;
	}

	if(iFailState != TQUERY_SUCCESS) {
		if(iFailState == TQUERY_CONNECT_FAILED) {
			log_to_file(SQL_ERROR_LOG, "[SQL] Can't connect to server [%.2f]", fQueryTime);
			log_to_file(SQL_ERROR_LOG, "[SQL] Error #%i, %s", iErrorCode, szError);
		}
		else /*if(iFailState == TQUERY_QUERY_FAILED)*/ {
			SQL_GetQueryString(hQueryHandle, g_szQuery, charsmax(g_szQuery));
			log_to_file(SQL_ERROR_LOG, "[SQL] Query error!");
			log_to_file(SQL_ERROR_LOG, "[SQL] Error #%i, %s", iErrorCode, szError);
			log_to_file(SQL_ERROR_LOG, "[SQL] Query: %s", g_szQuery);
		}

		return;
	}

	switch(eSqlData[SQL_DATA__QUERY_TYPE]) {
		case QUERY__CREATE_TABLE: {
			if(g_eCvar[CVAR__PRUNE_DAYS] > 0) {
				PruneExpiredRows();
				return;
			}

			SetSystemReady();
		}

		case QUERY__PRUNE_EXPIRED_ROWS: {
			SetSystemReady();
		}

		case QUERY__LOAD_PLAYER: {
			new pPlayer = find_player("k", eSqlData[SQL_DATA__USERID]);

			if(!pPlayer) {
				return;
			}

			g_bPlayerDataLoaded[pPlayer] = true;

			if(SQL_NumResults(hQueryHandle)) {
				g_iCoins[pPlayer] = min(g_eCvar[CVAR__COINS_TO_REWARD] - 1, SQL_ReadResult(hQueryHandle, 0));
				return;
			}

			new szAuthID[MAX_AUTHID_LENGTH];
			get_user_authid(pPlayer, szAuthID, charsmax(szAuthID));
			formatex(g_szQuery, charsmax(g_szQuery), "INSERT INTO `%s` (`steamid`, `coin`) VALUES ('%s', '0');", g_eCvar[CVAR__SQL_TABLE], szAuthID);
			MakeQuery(QUERY__INSERT_PLAYER);
		}
	}
}

SavePlayerData(pPlayer) {
	new szAuthID[MAX_AUTHID_LENGTH];
	get_user_authid(pPlayer, szAuthID, charsmax(szAuthID));
	formatex(g_szQuery, charsmax(g_szQuery), "UPDATE `%s` SET `coin` = '%i', `time_join` = CURRENT_TIMESTAMP WHERE `steamid` = '%s';", g_eCvar[CVAR__SQL_TABLE], g_iCoins[pPlayer], szAuthID);
	MakeQuery(QUERY__SAVE_PLAYER);
}

public plugin_end() {
	g_bPluginEnded = true;
}

SetSystemReady() {
	g_bSystemLoaded = true;

	RegisterHookChain(RG_CSGameRules_RestartRound, "CSGameRules_RestartRound_Pre");

	hook_cvar_change(g_pCvar[PCVAR__ENABLED], "hook_CvarChange");

	if(get_pcvar_num(g_pCvar[PCVAR__ENABLED])) {
		EnableHookChain(g_hKilled);
		SetHudInformerTask();
	}

	new pPlayers[MAX_PLAYERS], iPlCount;
	get_players(pPlayers, iPlCount, "ch");

	for(new i; i < iPlCount; i++) {
		LoadPlayerData(pPlayers[i]);
	}
}

stock GetEnding(iValue, const szA[], const szB[], const szC[], szBuffer[], iMaxLen) {
	iValue = abs(iValue);
	new iValue100 = iValue % 100, iValue10 = iValue % 10;

	if(iValue100 >= 5 && iValue100 <= 20 || iValue10 == 0 || iValue10 >= 5 && iValue10 <= 9) {
		copy(szBuffer, iMaxLen, szA);
		return;
	}

	if(iValue10 == 1) {
		copy(szBuffer, iMaxLen, szB);
		return;
	}

	/*if(iValue10 >= 2 && iValue10 <= 4) {
		copy(szBuffer, iMaxLen, szC)
	}*/

	copy(szBuffer, iMaxLen, szC);
}

stock precache_model_safe(const szModel[], bool:bCanBeEmpty = false) {
	if(!szModel[0]) {
		if(!bCanBeEmpty) {
			set_fail_state("Found empty model string while 'bCanBeEmpty' is false");
		}

		return 0;
	}

	if(!file_exists(szModel)) {
		set_fail_state("Can't find model '%s'", szModel);
	}

	return precache_model(szModel);
}

public plugin_natives() {
	set_native_filter("native_filter");
}

//  *   trap        - 0 if native couldn't be found, 1 if native use was attempted
public native_filter(const szNativeName[], iNativeID, iTrapMode) {
	return !iTrapMode;
}