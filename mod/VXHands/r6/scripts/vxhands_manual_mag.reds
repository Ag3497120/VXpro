// SPDX-License-Identifier: MIT
// Optional VX Hands input overlay. The game owns the weapon and its ammunition.
@addField(WeaponObject)
// 0 ready, 1 ejected, 2 inserted, 3 refilling, 4 refilling while waiting
// for a pistol slide, 5 filled pistol waiting for slide, 6 slide pulled before refill,
// 7 verifying native refill, 8 verifying refill while waiting for the slide.
public let vxHandsMagazinePhase: Int32;
@addField(WeaponObject)
public let vxHandsReloadSequence: Int32;
@addField(WeaponObject)
public let vxHandsNeedsRack: Bool;

class VXHandsFinishReload extends Event {
    public let weapon: wref<WeaponObject>;
    public let sequence: Int32;
    public let ejected: Bool;
    public let attempt: Int32;
}

// The game consumes commands on its own thread. The native side keeps each
// request until this script acknowledges its exact weapon and serial number.
class VXHandsPollCommands extends Event {}

@addMethod(AnimationControllerComponent)
public func VXHandsProbePoseContext(owner: String) {
    ResourceMetricsReportGenerator.WriteReportToFile("VXW2|P|" + owner + "-controller");
}

@addMethod(IComponent)
public func VXHandsProbeRootContext(owner: String) {
    ResourceMetricsReportGenerator.WriteReportToFile("VXW2|P|" + owner + "-root");
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|" + owner + "-root-name|" + NameToString(this.GetName()));
}

@addMethod(PlayerPuppet)
public func VXHandsProbePoseContexts() {
    if !this.vxHandsCommandsRunning { return; }
    let controller = this.GetAnimationControllerComponent();
    if IsDefined(controller) { controller.VXHandsProbePoseContext("player"); }
    let root = this.FindComponentByName(n"root") as AnimatedComponent;
    if IsDefined(root) { root.VXHandsProbeRootContext("player"); }
    else { ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|player-root-missing"); }
    let weapon = this.VXHandsEquippedWeapon();
    if IsDefined(weapon) {
        weapon.VXHandsProbeWeaponController();
    }
}

@addMethod(WeaponObject)
public func VXHandsProbeWeaponController() {
    let controller = this.FindComponentByName(n"animController") as AnimationControllerComponent;
    if IsDefined(controller) { controller.VXHandsProbePoseContext("weapon"); }
    else { ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|weapon-controller-missing"); }
    let root = this.FindComponentByName(n"root") as AnimatedComponent;
    if IsDefined(root) { root.VXHandsProbeRootContext("weapon"); }
    else { ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|weapon-root-missing"); }
}

@addField(PlayerPuppet)
private let vxHandsCommandsRunning: Bool;
@addField(PlayerPuppet)
private let vxHandsLastCommand: String;
@addField(PlayerPuppet)
private let vxHandsLastAck: String;

@addMethod(PlayerPuppet)
public func VXHandsStartCommands() {
    if this.vxHandsCommandsRunning { return; }
    // Reserved literal for VXMac 2.5.0's opt-in native mailbox. With an older
    // host this is an ordinary number string, so the new driver stays disabled.
    let packet = IntToString(1448626226);
    if !StrBeginsWith(packet, "VXH2|") { return; }
    this.vxHandsCommandsRunning = true;
    this.VXHandsProbePoseContexts();
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|game-thread-commands-ready");
    GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, new VXHandsPollCommands(), 0.02, false);
}

@addMethod(PlayerPuppet)
protected cb func OnVXHandsPollCommands(event: ref<VXHandsPollCommands>) -> Bool {
    if this != GetPlayer(this.GetGame()) {
        this.vxHandsCommandsRunning = false;
        return true;
    }
    let packet = IntToString(1448626226);
    if !StrBeginsWith(packet, "VXH2|") {
        this.vxHandsCommandsRunning = false;
        return true;
    }
    let parts = StrSplit(packet, "|");
    if ArraySize(parts) == 5 {
        if Equals(packet, this.vxHandsLastCommand) {
            ResourceMetricsReportGenerator.WriteReportToFile(this.vxHandsLastAck);
        } else {
            let weapon = this.VXHandsEquippedWeapon();
            let accepted = false;
            if IsDefined(weapon) && Equals(parts[1], EntityID.ToDebugStringDecimal(weapon.GetEntityID())) &&
                Equals(parts[2], ToString(TDBID.ToNumber(ItemID.GetTDBID(weapon.GetItemID())))) {
                accepted = this.VXHandsExecuteMagazineCommand(weapon, StringToInt(parts[4]));
            }
            this.vxHandsLastCommand = packet;
            this.vxHandsLastAck = "VXW2|A|" + parts[1] + "|" + parts[2] + "|" + parts[3] + "|" + parts[4]
                + (accepted ? "|0" : "|1");
            ResourceMetricsReportGenerator.WriteReportToFile(this.vxHandsLastAck);
            this.VXHandsReportReload(weapon);
        }
    }
    GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, new VXHandsPollCommands(), 0.02, false);
    return true;
}

@addMethod(PlayerPuppet)
public func VXHandsReportReload(weapon: wref<WeaponObject>) {
    if !IsDefined(weapon) { return; }
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|reload-report-enter");
    let kind = weapon.IsRanged() ? 2 : 0;
    if Equals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Wea_Handgun) { kind = 1; }
    if Equals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Wea_Revolver) { kind = 3; }
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|R|"
        + EntityID.ToDebugStringDecimal(weapon.GetEntityID()) + "|"
        + ToString(TDBID.ToNumber(ItemID.GetTDBID(weapon.GetItemID()))) + "|"
        + IntToString(kind) + "|" + IntToString(weapon.vxHandsMagazinePhase) + "|"
        + ToString(WeaponObject.GetMagazineAmmoCount(weapon)) + "|"
        + ToString(WeaponObject.GetMagazineCapacity(weapon)) + "|" + IntToString(weapon.vxHandsReloadSequence));
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|reload-report-done");
}

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
    let result = wrappedMethod();
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|game-attached");
    this.RegisterInputListener(this, n"Reload");
    this.RegisterInputListener(this, n"VXHandsEject");
    this.RegisterInputListener(this, n"VXHandsInsert");
    this.RegisterInputListener(this, n"VXHandsChamber");
    this.VXHandsStartCommands();
    return result;
}

@addMethod(PlayerPuppet)
private func VXHandsEquippedWeapon() -> wref<WeaponObject> {
    return GameInstance.GetTransactionSystem(this.GetGame())
        .GetItemInSlot(this, t"AttachmentSlots.WeaponRight") as WeaponObject;
}

@addMethod(PlayerPuppet)
public func VXHandsEjectMagazine(weapon: wref<WeaponObject>) {
    if !IsDefined(weapon) || !weapon.IsRanged() || WeaponObject.GetMagazineCapacity(weapon) == 0u {
        return;
    }
    if weapon.vxHandsMagazinePhase == 1 {
        return;
    }
    weapon.vxHandsReloadSequence += 1;
    if weapon.vxHandsMagazinePhase == 3 || weapon.vxHandsMagazinePhase == 4 {
        weapon.StopReload(gameweaponReloadStatus.Interrupted);
    }
    weapon.vxHandsMagazinePhase = 1;
    weapon.vxHandsNeedsRack = true;
    // The stock weapon handler consumes rounds from the currently fitted magazine.
    let count = WeaponObject.GetMagazineAmmoCount(weapon);
    if count > 0u {
        let empty = new WeaponConsumeMagazineAmmoEvent();
        empty.amount = Cast<Uint16>(count);
        weapon.QueueEvent(empty);
    }
    let confirm = new VXHandsFinishReload();
    confirm.weapon = weapon;
    confirm.sequence = weapon.vxHandsReloadSequence;
    confirm.ejected = true;
    GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, confirm, 0.08, false);
}

@wrapMethod(PlayerPuppet)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
    let command = ListenerAction.GetName(action);
    if NotEquals(command, n"Reload") && NotEquals(command, n"VXHandsEject") &&
        NotEquals(command, n"VXHandsInsert") && NotEquals(command, n"VXHandsChamber") {
        return wrappedMethod(action, consumer);
    }
    if this.vxHandsCommandsRunning { return true; }
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|action|" + NameToString(command));
    let inputType = ListenerAction.GetType(action);
    if NotEquals(inputType, gameinputActionType.BUTTON_PRESSED) &&
        !(Equals(command, n"Reload") && Equals(inputType, gameinputActionType.BUTTON_RELEASED)) {
        return true;
    }
    let weapon = this.VXHandsEquippedWeapon();
    if !IsDefined(weapon) || !weapon.IsRanged() || WeaponObject.GetMagazineCapacity(weapon) == 0u {
        return wrappedMethod(action, consumer);
    }
    let kind = Equals(command, n"Reload") || Equals(command, n"VXHandsEject") ? 1 :
        (Equals(command, n"VXHandsInsert") ? 2 : 3);
    this.VXHandsExecuteMagazineCommand(weapon, kind);
    this.VXHandsReportReload(weapon);
    return true;
}

@addMethod(PlayerPuppet)
private func VXHandsExecuteMagazineCommand(weapon: wref<WeaponObject>, command: Int32) -> Bool {
    if !IsDefined(weapon) || !weapon.IsRanged() || WeaponObject.GetMagazineCapacity(weapon) == 0u { return false; }
    if command == 1 {
        this.VXHandsEjectMagazine(weapon);
    } else if command == 2 && weapon.vxHandsMagazinePhase == 1 {
        weapon.vxHandsMagazinePhase = 2;
        // The same completion handler verifies ejection before starting
        // inventory accounting. Duplicate confirmations carry the old sequence.
        let confirm = new VXHandsFinishReload();
        confirm.weapon = weapon;
        confirm.sequence = weapon.vxHandsReloadSequence;
        confirm.ejected = true;
        GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, confirm, 0.08, false);
    } else if command == 3 &&
        Equals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Wea_Handgun) {
        if (weapon.vxHandsMagazinePhase == 0 || weapon.vxHandsMagazinePhase == 5) && !weapon.IsMagazineEmpty() {
            weapon.vxHandsMagazinePhase = 0;
            weapon.vxHandsNeedsRack = false;
            ScriptLog("VX Hands: game confirmed manual chamber");
        } else if weapon.vxHandsMagazinePhase == 2 {
            weapon.vxHandsMagazinePhase = 6;
        } else if weapon.vxHandsMagazinePhase == 4 {
            weapon.vxHandsMagazinePhase = 3;
        } else if weapon.vxHandsMagazinePhase == 8 {
            weapon.vxHandsMagazinePhase = 7;
        } else { return false; }
    } else { return false; }
    return true;
}

@addMethod(PlayerPuppet)
protected cb func OnVXHandsFinishReload(event: ref<VXHandsFinishReload>) -> Bool {
    let weapon = event.weapon;
    if !IsDefined(weapon) || weapon.vxHandsReloadSequence != event.sequence {
        return true;
    }
    if event.ejected {
        if weapon == this.VXHandsEquippedWeapon() {
            let remaining = WeaponObject.GetMagazineAmmoCount(weapon);
            if remaining == 0u {
                WeaponObject.SendAmmoUpdateEvent(this, weapon);
                ScriptLog("VX Hands: game confirmed empty magazine");
                if (weapon.vxHandsMagazinePhase == 2 || weapon.vxHandsMagazinePhase == 6) && WeaponObject.CanReload(weapon) {
                    let manual = Equals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Wea_Handgun) &&
                        weapon.vxHandsMagazinePhase != 6;
                    weapon.vxHandsMagazinePhase = manual ? 4 : 3;
                    weapon.vxHandsReloadSequence += 1;
                    // Refill on insertion for every gun. A handgun keeps its
                    // trigger locked until the separate physical slide action.
                    let duration = weapon.StartReload();
                    let finish = new VXHandsFinishReload();
                    finish.weapon = weapon;
                    finish.sequence = weapon.vxHandsReloadSequence;
                    GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, finish, MaxF(0.10, duration), false);
                }
            } else {
                if weapon.vxHandsMagazinePhase == 1 || weapon.vxHandsMagazinePhase == 2 || weapon.vxHandsMagazinePhase == 6 {
                    weapon.vxHandsMagazinePhase = 0;
                    weapon.vxHandsNeedsRack = false;
                }
                ScriptLogWarning("VX Hands: ejection left rounds in the magazine");
            }
        }
    } else if weapon.vxHandsMagazinePhase == 3 || weapon.vxHandsMagazinePhase == 4 {
        if weapon == this.VXHandsEquippedWeapon() {
            weapon.StopReload(gameweaponReloadStatus.Standard);
            weapon.vxHandsMagazinePhase = weapon.vxHandsMagazinePhase == 4 ? 8 : 7;
            let verify = new VXHandsFinishReload();
            verify.weapon = weapon;
            verify.sequence = event.sequence;
            verify.attempt = 1;
            // StopReload queues native weapon work. Read the magazine on a
            // later game tick instead of rejecting its still-empty blackboard.
            GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, verify, 0.10, false);
        } else {
            weapon.StopReload(gameweaponReloadStatus.Interrupted);
            weapon.vxHandsMagazinePhase = 1;
        }
    } else if weapon.vxHandsMagazinePhase == 7 || weapon.vxHandsMagazinePhase == 8 {
        if weapon != this.VXHandsEquippedWeapon() { return true; }
        if weapon.IsMagazineEmpty() && event.attempt < 5 {
            let verify = new VXHandsFinishReload();
            verify.weapon = weapon;
            verify.sequence = event.sequence;
            verify.attempt = event.attempt + 1;
            GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, verify, 0.10, false);
        } else {
            WeaponObject.SendAmmoUpdateEvent(this, weapon);
            let loaded = !weapon.IsMagazineEmpty();
            let pending = weapon.vxHandsMagazinePhase == 8;
            weapon.vxHandsMagazinePhase = loaded ? (pending ? 5 : 0) : 1;
            weapon.vxHandsNeedsRack = !loaded || pending;
            if loaded {
                ScriptLog(weapon.vxHandsNeedsRack ? "VX Hands: game confirmed magazine; waiting for slide" :
                    "VX Hands: game confirmed magazine and chamber");
            } else {
                ScriptLogWarning("VX Hands: refill completed without rounds");
            }
        }
    }
    this.VXHandsReportReload(weapon);
    return true;
}

@wrapMethod(EquipmentBaseTransition)
protected const final func HandleWeaponEquip(scriptInterface: StateGameScriptInterface, stateContext: StateContext,
    stateMachineInstanceData: StateMachineInstanceData, item: ItemID, isLeftWeapon: Bool) {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    let record = TweakDBInterface.GetWeaponItemRecord(ItemID.GetTDBID(item));
    if !IsDefined(player) || player != GetPlayer(scriptInterface.GetGame()) || isLeftWeapon ||
        !IsDefined(record) || NotEquals(record.ItemCategory().Type(), gamedataItemCategory.Weapon) ||
        WeaponObject.IsMelee(item) {
        wrappedMethod(scriptInterface, stateContext, stateMachineInstanceData, item, isLeftWeapon);
        return;
    }
    let flag = GetAllBlackboardDefs().PlayerStateMachine.ScenePreventFirstEquip;
    let prior = scriptInterface.localBlackboard.GetBool(flag);
    scriptInterface.localBlackboard.SetBool(flag, true);
    wrappedMethod(scriptInterface, stateContext, stateMachineInstanceData, item, isLeftWeapon);
    scriptInterface.localBlackboard.SetBool(flag, prior);
    let weapon = GameInstance.GetTransactionSystem(scriptInterface.GetGame())
        .GetItemInSlot(player, t"AttachmentSlots.WeaponRight") as WeaponObject;
    if IsDefined(weapon) && weapon.GetItemID() == item && weapon.vxHandsMagazinePhase == 0 && !weapon.IsMagazineEmpty() {
        // Old saves may retain the previous on-equip manual-rack flag.
        weapon.vxHandsNeedsRack = false;
    }
}

private func VXHandsRackPending(scriptInterface: StateGameScriptInterface) -> Bool {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    let weapon = scriptInterface.owner as WeaponObject;
    return IsDefined(player) && player == GetPlayer(scriptInterface.GetGame()) && IsDefined(weapon) && weapon.vxHandsNeedsRack;
}

@wrapMethod(WeaponTransition)
protected const final func ShouldShoot(scriptInterface: StateGameScriptInterface) -> Bool {
    return !VXHandsRackPending(scriptInterface) && wrappedMethod(scriptInterface);
}

@wrapMethod(ChargeDecisions)
protected const final func EnterCondition(const stateContext: StateContext, const scriptInterface: StateGameScriptInterface) -> Bool {
    return !VXHandsRackPending(scriptInterface) && wrappedMethod(stateContext, scriptInterface);
}

@wrapMethod(NoAmmoDecisions)
protected const func ToReload(const stateContext: StateContext, const scriptInterface: StateGameScriptInterface) -> Bool {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    let weapon = scriptInterface.owner as WeaponObject;
    if IsDefined(player) && player == GetPlayer(scriptInterface.GetGame()) && IsDefined(weapon) &&
        weapon.IsRanged() && WeaponObject.GetMagazineCapacity(weapon) > 0u {
        if scriptInterface.IsActionJustTapped(n"Reload") {
            player.VXHandsEjectMagazine(weapon);
        }
        return false;
    }
    return wrappedMethod(stateContext, scriptInterface);
}

@wrapMethod(ReloadDecisions)
protected const func EnterCondition(const stateContext: StateContext, const scriptInterface: StateGameScriptInterface) -> Bool {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    let weapon = scriptInterface.owner as WeaponObject;
    if IsDefined(player) && player == GetPlayer(scriptInterface.GetGame()) && IsDefined(weapon) &&
        weapon.IsRanged() && WeaponObject.GetMagazineCapacity(weapon) > 0u {
        if scriptInterface.IsActionJustTapped(n"Reload") {
            player.VXHandsEjectMagazine(weapon);
        }
        return false;
    }
    return wrappedMethod(stateContext, scriptInterface);
}
