function info = report_storage_demand(StorageSpec, ReceiveSpec, ReconSpec, PDISpec, TransmitSpec)
%REPORT_STORAGE_DEMAND  What a configuration asks of the drive, before it runs.
%
%  INFO = REPORT_STORAGE_DEMAND(StorageSpec, ReceiveSpec, ReconSpec, PDISpec,
%  TransmitSpec) prints the per-frame size of each saved stream and the write
%  rate the acquisition needs to sustain, and returns::
%
%    bytesPerFrame   total bytes written per frame across the enabled streams
%    framePeriodMs   acquisition time for one frame
%    neededGBs       sustained write rate the configuration requires
%
%  Call it after echoframe_validate_structs and before init_storage. A rate the
%  drive cannot hold shows up as writes queueing until the acquisition ring
%  wraps; check_storage_headroom reports that afterwards.
%
%  See also INIT_STORAGE, CHECK_STORAGE_HEADROOM.

% One frame is transmit/receive per event x nTransmissions x nRepeats.
framePeriod_s = double(ReceiveSpec.nTransmissions) * double(ReceiveSpec.nRepeats) / ...
                double(TransmitSpec.txrxFrameRate);
nzp = double(ReconSpec.nz);
nxp = double(ReconSpec.nx);

bytes_rf  = double(ReceiveSpec.nSamples) * double(ReceiveSpec.nTransmissions) * ...
            double(ReceiveSpec.nRepeats) * double(ReceiveSpec.nChannels) * 2;
% Always 8: the BF handler is Storage::Handler<float2>, so complex single is what
% gets written whatever ReconSpec.bfDataType says.
bytes_bf  = nzp * nxp * double(ReceiveSpec.nRepeats) * 8;
nEns      = max(0, floor((double(ReceiveSpec.nRepeats) - double(PDISpec.ensembleSize)) / ...
                         double(PDISpec.shiftSize)) + 1);
bytes_pdi = nzp * nxp * nEns * 4;

bytes_total = StorageSpec.saveRF  * bytes_rf + ...
              StorageSpec.saveBF  * bytes_bf + ...
              StorageSpec.savePDI * bytes_pdi;

fprintf('\n---- storage demand for this configuration ----\n');
fprintf('  grid %dx%d, nRepeats %d, nTX %d, nSamples %d, nChannels %d\n', ...
        nzp, nxp, ReceiveSpec.nRepeats, ReceiveSpec.nTransmissions, ...
        ReceiveSpec.nSamples, ReceiveSpec.nChannels);
fprintf('  frame period      : %6.0f ms  (%.2f fps)\n', framePeriod_s*1e3, 1/framePeriod_s);
fprintf('  RF   per frame    : %8.1f MB  (saved: %d)\n', bytes_rf/2^20,  StorageSpec.saveRF);
fprintf('  BF   per frame    : %8.1f MB  (saved: %d)\n', bytes_bf/2^20,  StorageSpec.saveBF);
fprintf('  PDI  per frame    : %8.1f MB  (saved: %d)\n', bytes_pdi/2^20, StorageSpec.savePDI);
fprintf('  SUSTAINED WRITE NEEDED: %.2f GB/s\n', (bytes_total/2^30)/framePeriod_s);
fprintf('-----------------------------------------------\n\n');

info = struct('bytesPerFrame', bytes_total, ...
              'framePeriodMs', framePeriod_s*1e3, ...
              'neededGBs',     (bytes_total/2^30)/framePeriod_s);
end
