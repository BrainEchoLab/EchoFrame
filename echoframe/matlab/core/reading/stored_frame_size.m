function [nzOut, nxOut, isCropped] = stored_frame_size(ReconSpec, cropFlag)
%STORED_FRAME_SIZE  Frame size actually written to disk for a BF or PDI stream.
% Called by the read_stored_* inspection scripts and by the offline replay
% examples, so they all agree on what a stored frame looks like.
%
%  [nzOut, nxOut, isCropped] = STORED_FRAME_SIZE(ReconSpec, cropFlag) returns the
%  per-frame pixel dimensions of a stored stream.
%
%  cropFlag is the crop flag for the stream you are reading: ReconSpec.cropBF for
%  bf_acq.dat, PDISpec.cropPDI for pdi_acq.dat. It is passed in rather than read
%  from ReconSpec because the two streams are cropped independently.
%
%  When cropFlag is false the frame is the full reconstruction grid, nz x nx.
%  When it is true the storage layer wrote only ReconSpec.croppingROI, so the
%  frame is::
%
%    nzOut = croppingROI(2) - croppingROI(1) + 1
%    nxOut = croppingROI(4) - croppingROI(3) + 1
%
%  croppingROI is [zTop; zBottom; xLeft; xRight], **0-based and inclusive** - the
%  same convention the C++ crop kernel reads (mex_resources_conversions.cpp sets
%  nSamplesCropTop = croppingROI[0] directly). The size is the same either way,
%  but indexing the full frame in MATLAB needs +1::
%
%    rows = (croppingROI(1)+1):(croppingROI(2)+1)
%    cols = (croppingROI(3)+1):(croppingROI(4)+1)
%
%  Outputs are double, so they can be multiplied out without int32 saturation.
%
%  See also read_stored_BF, read_stored_PDI, init_storage.

if nargin < 2
    error('stored_frame_size:missingCropFlag', ...
          ['Pass the crop flag for the stream being read: ReconSpec.cropBF for ', ...
           'bf_acq.dat, PDISpec.cropPDI for pdi_acq.dat.']);
end

isCropped = logical(cropFlag);

if isCropped
    roi = double(ReconSpec.croppingROI);
    if numel(roi) ~= 4
        error('stored_frame_size:badROI', ...
              'ReconSpec.croppingROI must have 4 elements [zTop; zBottom; xLeft; xRight], got %d.', ...
              numel(roi));
    end
    nzOut = roi(2) - roi(1) + 1;
    nxOut = roi(4) - roi(3) + 1;
    if nzOut < 1 || nxOut < 1
        error('stored_frame_size:emptyROI', ...
              'croppingROI [%g %g %g %g] gives a %g x %g frame; bounds are inclusive and must increase.', ...
              roi(1), roi(2), roi(3), roi(4), nzOut, nxOut);
    end
else
    nzOut = double(ReconSpec.nz);
    nxOut = double(ReconSpec.nx);
end
end
