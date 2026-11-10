// SPDX-License-Identifier: MIT
// Optional VX Hands input overlay. The game owns the weapon and its ammunition.
@addField(WeaponObject)
// 0 ready, 1 ejected, 2 inserted, 3 refilling, 4 refilling while waiting
// for a pistol slide, 5 seated pistol magazine waiting for slide (native ammo still empty), 6 slide pulled before refill,
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

// Ordinary IntToString on an older host returns the literal number: retain
// tracked interaction there. The host's reserved query changes ownership only.
public func VXHandsTrackingEnabled() -> Bool {
    return NotEquals(IntToString(1448627506), "0");
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
@addField(PlayerPuppet)
private let vxHandsContextTick: Int32;
@addField(PlayerPuppet)
private let vxHandsLastContext: String;
@addField(PlayerPuppet)
private let vxHandsMenuCallback: CallbackHandle;
@addField(PlayerPuppet)
private let vxHandsFootFOV: Float;
@addField(PlayerPuppet)
private let vxHandsVehiclePitchReady: Bool;
@addField(PlayerPuppet)
private let vxHandsMountViewRequested: Bool;

@addMethod(PlayerPuppet)
public func VXHandsVehicleViewEnabled() -> Bool {
    return this.vxHandsCommandsRunning;
}

@addMethod(PlayerPuppet)
public func VXHandsSetVehiclePitchReady(ready: Bool) {
    this.vxHandsVehiclePitchReady = ready;
}

// Read the lens for diagnostics only. Vehicle look and seat-camera setup are
// independent of it; no FOV property is written by this overlay.
@addMethod(PlayerPuppet)
private func VXHandsVehicleView(mounted: Bool, mode: Int32, tier: Int32) {
    let camera = this.GetFPPCameraComponent();
    if !IsDefined(camera) { return; }
    let ui = GameInstance.GetBlackboardSystem(this.GetGame()).Get(GetAllBlackboardDefs().UI_System);
    let menu = IsDefined(ui) && ui.GetBool(GetAllBlackboardDefs().UI_System.IsInMenu);
    let nativeFOV = GameInstance.GetCameraSystem(this.GetGame()).GetActiveCameraFOV();
    let perspective: Int32 = 7;
    let vehicle = this.GetMountedVehicle();
    if mounted && IsDefined(vehicle) {
        perspective = EnumInt(vehicle.GetCameraManager().GetActivePerspective());
    }
    let normalView = !menu && tier < 2;
    let driverView = mounted && normalView && (mode == 1 || mode == 3);
    if this.vxHandsFootFOV <= 0.0 && camera.GetFOV() > 20.0 && camera.GetFOV() < 140.0 {
        this.vxHandsFootFOV = camera.GetFOV(); // direct load in a vehicle: component's base lens until a foot sample
    }
    if !mounted {
        this.vxHandsMountViewRequested = false;
        if normalView && camera.GetZoom() <= 1.05 && nativeFOV > 20.0 && nativeFOV < 140.0 {
            this.vxHandsFootFOV = nativeFOV;
        }
    }
    // Start a new VR ride at the seat, not on a camera orbit metres away.
    // Do not request a camera during a scene/transition or keep fighting a later
    // manual perspective switch. Confirmation comes from GetActivePerspective.
    if driverView && !this.vxHandsMountViewRequested {
        let request = new vehicleRequestCameraPerspectiveEvent();
        request.cameraPerspective = vehicleCameraPerspective.FPP;
        this.QueueEvent(request);
        this.vxHandsMountViewRequested = true;
    }
    if driverView && perspective == 0 && !this.vxHandsVehiclePitchReady {
        // A save can load already mounted, before the host mailbox is ready at
        // the normal vehicle setup boundary. Apply the same inputs once here.
        let look = new AnimFeature_CameraGameplay();
        look.is_pitch_off = 0.0;
        look.is_yaw_off = 0.0;
        AnimationControllerComponent.ApplyFeature(this, n"CameraGameplay", look);
        AnimationControllerComponent.ApplyFeature(this, n"CameraBodyOffset", new AnimFeature_CameraBodyOffset());
        this.vxHandsVehiclePitchReady = true;
    }
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|J|" + IntToString(perspective) + "|" +
        (this.vxHandsVehiclePitchReady ? "1" : "0") + "|0|" +
        FloatToString(nativeFOV) + "|" + FloatToString(this.vxHandsFootFOV));
}

// A VR camera looks independently of the animated upper body. Vehicle records
// can disable pitch and add look-dependent camera translation. Replace those
// two animation inputs at their native setup boundary, not by accumulating mouse
// corrections against a disabled axis. The game's reset still runs on exit.
@wrapMethod(VehicleTransition)
protected final func SetVehFppCameraParams(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>,
    isPassenger: Bool, opt side: Bool, opt combat: Bool) {
    wrappedMethod(stateContext, scriptInterface, isPassenger, side, combat);
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if !IsDefined(player) || !player.VXHandsVehicleViewEnabled() { return; }
    player.VXHandsSetVehiclePitchReady(!combat);
    if combat { return; }
    let look = new AnimFeature_CameraGameplay();
    look.is_pitch_off = 0.0;
    look.is_yaw_off = 0.0;
    scriptInterface.SetAnimationParameterFeature(n"CameraGameplay", look, player);
    scriptInterface.SetAnimationParameterFeature(n"CameraBodyOffset", new AnimFeature_CameraBodyOffset(), player);
}

@wrapMethod(VehicleTransition)
protected final func ResetVehFppCameraParams(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) {
    wrappedMethod(stateContext, scriptInterface);
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) { player.VXHandsSetVehiclePitchReady(false); }
}

@addMethod(PlayerPuppet)
protected cb func OnVXHandsMenuChanged(open: Bool) -> Bool {
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|M|" + (open ? "1" : "0"));
    return true;
}

@addMethod(PlayerPuppet)
public func VXHandsPublishContext() {
    let board = GameInstance.GetBlackboardSystem(this.GetGame())
        .GetLocalInstanced(this.GetEntityID(), GetAllBlackboardDefs().PlayerStateMachine);
    if !IsDefined(board) { return; }
    let mounted = VehicleComponent.IsMountedToVehicle(this.GetGame(), this);
    let vehicle = board.GetInt(GetAllBlackboardDefs().PlayerStateMachine.Vehicle);
    let scene = board.GetInt(GetAllBlackboardDefs().PlayerStateMachine.HighLevel);
    let report = "VXW1|C|" + (mounted ? "1" : "0") + "|" + IntToString(vehicle) + "|" + IntToString(scene);
    this.VXHandsVehicleView(mounted, vehicle, scene);
    this.vxHandsContextTick += 1;
    if NotEquals(report, this.vxHandsLastContext) || this.vxHandsContextTick >= 5 {
        this.vxHandsLastContext = report;
        this.vxHandsContextTick = 0;
        ResourceMetricsReportGenerator.WriteReportToFile("VXW1|V|6");
        ResourceMetricsReportGenerator.WriteReportToFile(report);
        let ui = GameInstance.GetBlackboardSystem(this.GetGame()).Get(GetAllBlackboardDefs().UI_System);
        if IsDefined(ui) { this.OnVXHandsMenuChanged(ui.GetBool(GetAllBlackboardDefs().UI_System.IsInMenu)); }
    }
}

@addMethod(PlayerPuppet)
public func VXHandsStartCommands() {
    if this.vxHandsCommandsRunning { return; }
    // Reserved literal for VXMac 2.5.0's opt-in native mailbox. With an older
    // host this is an ordinary number string, so the new driver stays disabled.
    let packet = IntToString(1448626226);
    if !StrBeginsWith(packet, "VXH2|") { return; }
    this.vxHandsCommandsRunning = true;
    // A paused menu can suspend the game-time poll. Its blackboard callback
    // still reports the transition; cursor association alone also occurs in dialogue.
    let ui = GameInstance.GetBlackboardSystem(this.GetGame()).Get(GetAllBlackboardDefs().UI_System);
    if IsDefined(ui) && !IsDefined(this.vxHandsMenuCallback) {
        this.vxHandsMenuCallback = ui.RegisterListenerBool(GetAllBlackboardDefs().UI_System.IsInMenu,
            this, n"OnVXHandsMenuChanged", true);
    }
    this.VXHandsProbePoseContexts();
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|T|game-thread-commands-ready");
    GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, new VXHandsPollCommands(), 0.02, false);
}

@addField(PlayerPuppet)
private let vxHandsModeKnown: Bool;
@addField(PlayerPuppet)
private let vxHandsModeTracking: Bool;
@addMethod(PlayerPuppet)
private func VXHandsUpdateControlMode() {
    let tracking = VXHandsTrackingEnabled();
    if this.vxHandsModeKnown && tracking != this.vxHandsModeTracking {
        let weapon = this.VXHandsEquippedWeapon();
        if IsDefined(weapon) {
            // Cancel only our delayed completion. Native ammo/inventory and
            // native controller reloads remain owned by the game.
            weapon.vxHandsReloadSequence += 1;
            if weapon.vxHandsMagazinePhase == 3 || weapon.vxHandsMagazinePhase == 4 {
                weapon.StopReload(gameweaponReloadStatus.Interrupted);
                weapon.vxHandsMagazinePhase = 1;
            }
            if !weapon.IsMagazineEmpty() {
                weapon.vxHandsMagazinePhase = 0;
                weapon.vxHandsNeedsRack = false;
            }
            this.VXHandsReportReload(weapon);
        }
    }
    this.vxHandsModeKnown = true;
    this.vxHandsModeTracking = tracking;
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|D|" + (tracking ? "1" : "0"));
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
    this.VXHandsUpdateControlMode();
    this.VXHandsPublishContext();
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

@addMethod(PlayerPuppet)
private func VXHandsFillPistolAfterRack(weapon: wref<WeaponObject>) -> Bool {
    if !IsDefined(weapon) || !WeaponObject.CanReload(weapon) { return false; }
    // Native ammo changes also drive the slide's animation graph. Do this
    // only after the physical rack, including on render parts we cannot skin.
    let fill = new SetAmmoCountEvent();
    fill.ammoTypeID = WeaponObject.GetAmmoType(weapon);
    fill.count = Cast<Uint32>(Min(Cast<Int32>(WeaponObject.GetMagazineCapacity(weapon)), Max(0, weapon.GetTotalAmmoCount())));
    weapon.vxHandsMagazinePhase = 7;
    weapon.vxHandsReloadSequence += 1;
    weapon.QueueEvent(fill);
    let verify = new VXHandsFinishReload();
    verify.weapon = weapon;
    verify.sequence = weapon.vxHandsReloadSequence;
    verify.attempt = 1;
    GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, verify, 0.10, false);
    return true;
}

@wrapMethod(PlayerPuppet)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
    if !VXHandsTrackingEnabled() || VehicleComponent.IsMountedToVehicle(this.GetGame(), this) {
        return wrappedMethod(action, consumer);
    }
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
    if !VXHandsTrackingEnabled() || !IsDefined(weapon) || !weapon.IsRanged() || WeaponObject.GetMagazineCapacity(weapon) == 0u { return false; }
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
        if weapon.vxHandsMagazinePhase == 5 && weapon.IsMagazineEmpty() {
            return this.VXHandsFillPistolAfterRack(weapon);
        } else if (weapon.vxHandsMagazinePhase == 0 || weapon.vxHandsMagazinePhase == 5) && !weapon.IsMagazineEmpty() {
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
    if !VXHandsTrackingEnabled() { return true; }
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
                    let handgun = Equals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Wea_Handgun);
                    let manual = handgun && weapon.vxHandsMagazinePhase != 6;
                    if handgun {
                        if manual {
                            weapon.vxHandsMagazinePhase = 5;
                            weapon.vxHandsNeedsRack = true;
                            weapon.vxHandsReloadSequence += 1;
                        } else {
                            this.VXHandsFillPistolAfterRack(weapon);
                        }
                    } else {
                        weapon.vxHandsMagazinePhase = 3;
                        weapon.vxHandsReloadSequence += 1;
                        let finish = new VXHandsFinishReload();
                        finish.weapon = weapon;
                        finish.sequence = weapon.vxHandsReloadSequence;
                        let duration = weapon.StartReload();
                        GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, finish, MaxF(0.10, duration), false);
                    }
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
    if !VXHandsTrackingEnabled() || !IsDefined(player) || player != GetPlayer(scriptInterface.GetGame()) || isLeftWeapon ||
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
    return VXHandsTrackingEnabled() && IsDefined(player) && player == GetPlayer(scriptInterface.GetGame()) &&
        !VehicleComponent.IsMountedToVehicle(player.GetGame(), player) && IsDefined(weapon) && weapon.vxHandsNeedsRack;
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
    if VXHandsTrackingEnabled() && IsDefined(player) && player == GetPlayer(scriptInterface.GetGame()) &&
        !VehicleComponent.IsMountedToVehicle(player.GetGame(), player) && IsDefined(weapon) &&
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
    if VXHandsTrackingEnabled() && IsDefined(player) && player == GetPlayer(scriptInterface.GetGame()) &&
        !VehicleComponent.IsMountedToVehicle(player.GetGame(), player) && IsDefined(weapon) &&
        weapon.IsRanged() && WeaponObject.GetMagazineCapacity(weapon) > 0u {
        if scriptInterface.IsActionJustTapped(n"Reload") {
            player.VXHandsEjectMagazine(weapon);
        }
        return false;
    }
    return wrappedMethod(stateContext, scriptInterface);
}
