% setup_echoframe_figure - Live B-mode + PDI + timing figure for the fUS example.
%
% Creates the two image axes and the acquisition timeline, and publishes their
% handles to the base workspace, where ef_external_process.m updates them each
% frame.
%
% The timeline plots the EchoFrame processing time and the whole Verasonics
% loop period against the acquisition period, so a loop that stops keeping up
% is visible while it happens rather than afterwards in the log.
%
% Reads EF_BUDGET_MS (the acquisition period) and EF_TIMELINE_ACQS from the base
% workspace; echoframe_acquisition_start.m sets both before calling this.
%
% Called by echoframe_acquisition_start.m.

global ReconSpec ReceiveSpec TransmitSpec

%% Dimensions of the images
Bmode_dim = ReconSpec.imageSize;
PDI_dim   = ReconSpec.imageSize;

% Published by the acquisition script; derived here when it is not, so the
% figure can be built on its own (see verify_verasonics_setup).
if evalin('base', 'exist(''EF_BUDGET_MS'', ''var'')')
    budget_ms = evalin('base', 'EF_BUDGET_MS');
else
    budget_ms = double(ReceiveSpec.nTransmissions) * double(ReceiveSpec.nRepeats) / ...
                double(TransmitSpec.txrxFrameRate) * 1e3;
end
if evalin('base', 'exist(''EF_TIMELINE_ACQS'', ''var'')')
    timelineLength = evalin('base', 'EF_TIMELINE_ACQS');
else
    timelineLength = 20;
end

%% Create a single figure for both images and the timeline
figHandle = figure('Name', 'EchoFrame', 'NumberTitle', 'off');
figHandle.Color = [1 1 1];
scrnsz = get(0,'screensize');
set(figHandle, 'Position', [scrnsz(1) 300 round(scrnsz(3)/1.5) scrnsz(4)/1.5]);
set(figHandle, 'MenuBar', 'none');

%% B-mode
subplot(4,4,[1 2 5 6 9 10]);
bmode_im = imagesc(ReconSpec.xAxis, ReconSpec.zAxis, randn(Bmode_dim)); % Placeholder data
ax1 = bmode_im.Parent;
title(ax1, 'B-mode Image');
colormap(ax1, gray);
clim(ax1, [-50 0]);
cb1 = colorbar(ax1);
cb1.Label.String = 'Amplitude [dB]';
axis(ax1, 'equal', 'tight');
xlabel('Width [mm]')
ylabel('Depth [mm]')

%% PDI
subplot(4,4,[3 4 7 8 11 12]);
pdi_im = imagesc(ReconSpec.xAxis, ReconSpec.zAxis, randn(PDI_dim)); % Placeholder data
ax2 = pdi_im.Parent;
title(ax2, 'Power Doppler Image');
colormap(ax2, hot);
clim(ax2, [-8 0]);
cb2 = colorbar(ax2);
cb2.Label.String = 'Amplitude [dB]';
axis(ax2, 'equal', 'tight');
ax2.YTick = [];
xlabel('Width [mm]')

%% Acquisition timeline
subplot(4,4,[13 14 15]);
hold on;
echoframeTimePlot = plot(1:timelineLength, nan(1, timelineLength), '-k.');
vsxCallTimePlot   = plot(1:timelineLength, nan(1, timelineLength), '-b.');
xlabel('Acquisition');
ylabel('Time (ms)');
grid on;
ylim([0, budget_ms * 2]);
xlim([1, timelineLength]);
xticks(1:1:timelineLength);
% Anything above this line did not fit the acquisition period.
yline(budget_ms, 'r--', 'LineWidth', 0.5);
yticks(unique(sort([yticks, budget_ms])));
timing_axes = gca;
legend('EchoFrame', 'Verasonics', 'PDI time')

%% Store handles in the base workspace for access in the processing script
assignin('base', 'bmode_im', bmode_im);
assignin('base', 'pdi_im', pdi_im);
assignin('base', 'echoframeTimePlot', echoframeTimePlot);
assignin('base', 'vsxCallTimePlot', vsxCallTimePlot);
assignin('base', 'timing_axes', timing_axes);

%% Live disk-usage bar, in the last cell of the 4x4 grid
% Refreshed from the acquisition loop rather than a timer: MATLAB timers are not
% reliably serviced while VSX is running the sequence. Skipped when there is no
% StorageSpec, i.e. when the figure is being set up outside an acquisition.
if exist('StorageSpec', 'var') && isfield(StorageSpec, 'folderStoragePath')
    echoframe_disk_monitor('start', StorageSpec.folderStoragePath);
end
