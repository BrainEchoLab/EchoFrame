/**
 * @file ffdas_beamformer.h
 * @brief ffdas-backed delay-and-sum beamformer.
 */
#pragma once

#include <cstdint>

#include <ffdas.h>

#include "../beamformer.h"
#include "das_recon_spec.h"

namespace Beamform {

template <typename bfType_t>
class FFDASBeamformer : public Beamformer<bfType_t> {
   private:
    DASReconSpec dasReconSpec;

    ffdas_handle_t handle{};
    ffdas_tensor_desc_t xDesc{};
    ffdas_tensor_desc_t outDesc{};

    bool mInitialized{false};

   public:
    FFDASBeamformer() = default;

    FFDASBeamformer(ReceiveSpec pReceiveSpec, ReconSpec pReconSpec,
                    DASReconSpec pDASReconSpec, bfType_t *d_pRF)
        : Beamformer<bfType_t>(std::move(pReceiveSpec), pReconSpec, d_pRF),
          dasReconSpec(pDASReconSpec) {
        initialize();
        mInitialized = true;
    }

    ~FFDASBeamformer();

    FFDASBeamformer(FFDASBeamformer &&x) noexcept = delete;
    FFDASBeamformer &operator=(FFDASBeamformer &&x) noexcept = delete;

    void initialize();
    void initGPU();
    void clearGPU();
    void process();
};

}  // namespace Beamform
