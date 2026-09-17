import numpy as np
import matplotlib.pyplot as plt
import h5py

# !!! Manually define the file path and file name !!!
load_path = ""
filename = "pdi_acq"

# Construct the full filepath and open the file.
filepath = load_path + filename + ".dat"
fileID = open(filepath, "rb")

# Load the Reconstruction Spec from the ScanParameters.mat file.
scanParametersPath = load_path + "ScanParameters.mat"
with h5py.File(scanParametersPath, "r") as file:
    ReconSpec = file["ReconSpec"]
    ReceiveSpec = file['ReceiveSpec']
    PDISpec = file['PDISpec']

    cropPDI = bool(np.array(PDISpec['cropPDI'][()])) if 'cropPDI' in PDISpec else False

    if cropPDI:
        nz = int(np.array(ReconSpec['croppingROI'][0][1]) - np.array(ReconSpec['croppingROI'][0][0]) + 1)
        nx = int(np.array(ReconSpec['croppingROI'][0][3]) - np.array(ReconSpec['croppingROI'][0][2]) + 1)
    else:
        nz = int(np.array(ReconSpec['nz'][()]))
        nx = int(np.array(ReconSpec['nx'][()]))
    nRepeats = int(np.array(ReceiveSpec['nRepeats'][()]))
    ensembleSize = int(np.array(PDISpec['ensembleSize'][()]))
    shiftSize = int(np.array(PDISpec['shiftSize'][()]))
    nEnsembles = max(0, (nRepeats - ensembleSize) // shiftSize + 1)

# Read the header information:
# mBuffersDequeued: Read the number of PDI frames written to disk.
# effectiveBufferSize: Actual buffer size in total pixels (i.e., nx * nz).
numHeaderElements = 5
header = np.fromfile(fileID, dtype=np.uint64, count=numHeaderElements)
mVersion, mHeaderSize, mBuffersDequeued, effectiveBufferSize, mPaddingBytes = header

# Move the file read position to the end of the header.
fileID.seek(mHeaderSize, 0)

# Initialize a 3D array to accumulate the PDI frames.
PDI_frames = np.zeros((nz, nx, nEnsembles,mBuffersDequeued), dtype=np.float32)

for i in range(mBuffersDequeued):
    # Read a buffer of 'single' data
    data_chunk_single = np.fromfile(
        fileID, dtype=np.float32, count=int(effectiveBufferSize)
    )

    # Reshape the data chunk into the PDI matrix and transpose it
    # (Column-major MATLAB vs. row-major numpy).
    PDI = data_chunk_single.reshape(nEnsembles,nx, nz).T

    # Store this PDI frame in the complete 3D array with shape [nz, nx, mBuffersDequeued]
    # holding all PDI frames.
    PDI_frames[:, :, :, i] = PDI

    # Do something e.g., display a PDI frame (maybe don't do this with large datasets :)).
    for j in range (PDI.shape[2]):
        plt.figure(figsize=(6, 6))
        PDI_frame = PDI_frames[:, :, j, i]
        PDI_norm_db  = 10*np.log10(PDI_frame / max(PDI_frame))
        plt.imshow(PDI_norm_db, cmap="hot")
        plt.colorbar()
        plt.xlabel("Pixels in x direction")
        plt.ylabel("Pixels in z direction")
        plt.title(f"PDI Frame {j + 1} from buffer {i+1}")
        plt.show()
        plt.close()

    # Skip padding bytes before moving to the next buffer
    fileID.seek(mPaddingBytes, 1)  # Skip `mPaddingBytes` from the current position

# Close the file
fileID.close()
