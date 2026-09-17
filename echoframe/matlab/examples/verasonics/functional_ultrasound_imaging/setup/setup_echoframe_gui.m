% setup_echoframe_gui - Sliders and Store toggle for the Verasonics GUI.
%
% Adds the controls that change the reconstruction while it runs:
%
%   SVD Reject %       clutter (tissue) singular vectors removed
%   SVD noise          noise-subspace singular vectors removed
%   Transmit Aperture  transmit apodization width
%   Receive Aperture   receive apodization width
%   Store              start / stop writing the recording
%
% The sliders set a flag and let ef_external_process apply the change on its
% next frame, so nothing reaches the MEX from a GUI callback. The aperture
% sliders instead hand Verasonics an update&Run for TX / Receive.
%
% Turning Store off ends the recording and sets updateExperiment, so the next
% Store opens a fresh recording folder rather than appending to a file that has
% already been closed out.
%
% Called by echoframe_acquisition_start.m, before the workspace is saved for VSX.

global TransmitSpec ReceiveSpec ReconSpec

import vsv.seq.uicontrol.*

%% SVD
UI(1).Control = VsSliderControl( ...
    'LocationCode',    'UserB4', ...
    'Label',           'SVD Reject %', ...
    'SliderMinMaxVal', [0, 100, ReconSpec.svdRejectHighPercentage], ...
    'SliderStep',      [1/100, 1/100], ...
    'ValueFormat',     '%i', ...
    'Callback',        @SVD_cut_off_start);

UI(2).Control = VsSliderControl( ...
    'LocationCode',    'UserB3', ...
    'Label',           'SVD noise', ...
    'SliderMinMaxVal', [0, 100, ReconSpec.svdRejectLowPercentage], ...
    'SliderStep',      [1/200, 1/25], ...
    'ValueFormat',     '%1.1f', ...
    'Callback',        @SVD_cut_off_end);

%% Apodization
UI(3).Control = VsSliderControl( ...
    'LocationCode',    'UserA1', ...
    'Label',           'Transmit Aperture', ...
    'SliderMinMaxVal', [0, 100, TransmitSpec.aperturePercentage], ...
    'SliderStep',      [1/200, 1/25], ...
    'ValueFormat',     '%1.1f', ...
    'Callback',        @TransmitApodPerc);

UI(4).Control = VsSliderControl( ...
    'LocationCode',    'UserA2', ...
    'Label',           'Receive Aperture', ...
    'SliderMinMaxVal', [0, 100, ReceiveSpec.aperturePercentage], ...
    'SliderStep',      [1/200, 1/25], ...
    'ValueFormat',     '%1.1f', ...
    'Callback',        @ReceiveApodPerc);

%% Storage
UI(5).Control = VsToggleButtonControl( ...
    'LocationCode', 'UserB1', ...
    'Style',        'VsToggleButton', ...
    'Label',        'Store', ...
    'Callback',     @storeToggle);

% ef_external_process reaches for this to put the button back when the
% experiment reaches numberOfPDIsExperiment on its own.
assignin('base', 'storeButtonControl', UI(5).Control);

%% Functions
function SVD_cut_off_start(~, ~, UIValue)
ReconSpec = evalin('base', 'ReconSpec');
ReconSpec.svdRejectHighPercentage = round(UIValue);
assignin('base', 'ReconSpec', ReconSpec);
assignin('base', 'SVD_threshold', round(UIValue) * 0.01);
assignin('base', 'SVD_update_flag', 1);
end

function SVD_cut_off_end(~, ~, UIValue)
ReconSpec = evalin('base', 'ReconSpec');
ReconSpec.svdRejectLowPercentage = UIValue;
assignin('base', 'ReconSpec', ReconSpec);
assignin('base', 'SVD_lower_threshold', UIValue * 0.01);
assignin('base', 'SVD_lower_update_flag', 1);
end

function TransmitApodPerc(~, ~, UIValue)
TransmitSpec = evalin('base', 'TransmitSpec');
TransmitSpec.aperturePercentage = UIValue;
TransmitSpec.apodization = calculate_transmit_apodization( ...
    length(TransmitSpec.apodization), TransmitSpec.aperturePercentage);
assignin('base', 'TransmitSpec', TransmitSpec);

TX = evalin('base', 'TX');
for i = 1:length(TX)
    TX(i).Apod = TransmitSpec.apodization;
end
assignin('base', 'TX', TX);

Control = evalin('base', 'Control');
Control.Command = 'update&Run';
Control.Parameters = {'TX'};
assignin('base', 'Control', Control);
end

function ReceiveApodPerc(~, ~, UIValue)
ReceiveSpec = evalin('base', 'ReceiveSpec');
ReceiveSpec.aperturePercentage = UIValue;
ReceiveSpec.apodization = calculate_receive_apodization( ...
    length(ReceiveSpec.apodization), ReceiveSpec.aperturePercentage);
assignin('base', 'ReceiveSpec', ReceiveSpec);

Receive = evalin('base', 'Receive');
for i = 1:length(Receive)
    Receive(i).Apod = ReceiveSpec.apodization;
end
assignin('base', 'Receive', Receive);

Control = evalin('base', 'Control');
Control.Command = 'update&Run';
Control.Parameters = {'Receive'};
assignin('base', 'Control', Control);
end

function storeToggle(~, ~, UIState)
UI = evalin('base', 'UI');
updateStateSaveButton = evalin('base', 'updateStateSaveButton');

if UIState
    % Refuse a recording that will not fit.
    [disk_fits, disk_msg] = echoframe_disk_monitor('verify');
    if ~disk_fits
        UI(5).handle.Value = 0;
        set(UI(5).handle, 'String', 'NOT SAVING');
        assignin('base', 'save_rf_pdi', false);
        error('EchoFrame:InsufficientDiskSpace', '%s', disk_msg);
    end
    set(UI(5).handle, 'String', 'SAVING');
    assignin('base', 'save_rf_pdi', true);
else
    set(UI(5).handle, 'String', 'NOT SAVING');
    % Close this recording out; the next Store starts a new one.
    assignin('base', 'updateExperiment', 1);
    assignin('base', 'save_rf_pdi', false);
end

% The experiment filled its preallocated files and asked for the button back.
if UIState && updateStateSaveButton
    UI(5).handle.Value = 0;
    set(UI(5).handle, 'String', 'NOT SAVING');
    assignin('base', 'updateExperiment', 1);
    assignin('base', 'updateStateSaveButton', 0);
end
end
