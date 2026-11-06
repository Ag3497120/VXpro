// VX Hands: an empty magazine must wait for an explicit reload request.
// Compiled against the player's own script bundle; no game bundle is distributed.
@wrapMethod(NoAmmoDecisions)
protected const func ToReload(const stateContext: StateContext, const scriptInterface: StateGameScriptInterface) -> Bool {
    if !scriptInterface.IsActionJustPressed(n"Reload") {
        return false;
    }
    return wrappedMethod(stateContext, scriptInterface);
}
