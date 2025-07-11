/*
 * Copyright 2018, Google LLC.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package hipstershop;

import com.google.common.collect.ImmutableListMultimap;
import com.google.common.collect.ImmutableMap;
import com.google.common.collect.Iterables;
import hipstershop.Demo.Ad;
import hipstershop.Demo.AdRequest;
import hipstershop.Demo.AdResponse;
import io.grpc.Server;
import io.grpc.ServerBuilder;
import io.grpc.StatusRuntimeException;
import io.grpc.health.v1.HealthCheckResponse.ServingStatus;
import io.grpc.services.*;
import io.grpc.stub.StreamObserver;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Random;
import java.util.Date;
import java.util.concurrent.TimeUnit;
import org.apache.logging.log4j.Level;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

public final class AdService {

  private static final Logger logger = LogManager.getLogger(AdService.class);

  @SuppressWarnings("FieldCanBeLocal")
  private static int MAX_ADS_TO_SERVE = 2;

  private Server server;
  private HealthStatusManager healthMgr;

  private static final AdService service = new AdService();

  private void start() throws IOException {
    int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "9555"));
    healthMgr = new HealthStatusManager();

    server =
        ServerBuilder.forPort(port)
            .addService(new AdServiceImpl())
            .addService(healthMgr.getHealthService())
            .build()
            .start();
    logger.info("Ad Service started, listening on " + port);
    Runtime.getRuntime()
        .addShutdownHook(
            new Thread(
                () -> {
                  // Use stderr here since the logger may have been reset by its JVM shutdown hook.
                  System.err.println(
                      "*** shutting down gRPC ads server since JVM is shutting down");
                  AdService.this.stop();
                  System.err.println("*** server shut down");
                }));
    healthMgr.setStatus("", ServingStatus.SERVING);
  }

  private void stop() {
    if (server != null) {
      healthMgr.clearStatus("");
      server.shutdown();
    }
  }

  private static class AdServiceImpl extends hipstershop.AdServiceGrpc.AdServiceImplBase {

    /**
     * Retrieves ads based on context provided in the request {@code AdRequest}.
     *
     * @param req the request containing context.
     * @param responseObserver the stream observer which gets notified with the value of {@code
     *     AdResponse}
     */
    @Override
    public void getAds(AdRequest req, StreamObserver<AdResponse> responseObserver) {
      AdService service = AdService.getInstance();
      try {
        List<Ad> allAds = new ArrayList<>();
        logger.info("received ad request (context_words=" + req.getContextKeysList() + ")");
        logger.warn("Could this be the FLAG: NINTENDO64");
        if (req.getContextKeysCount() > 0) {
          for (int i = 0; i < req.getContextKeysCount(); i++) {
            Collection<Ad> ads = service.getAdsByCategory(req.getContextKeys(i));
            allAds.addAll(ads);
          }
        } else {
          allAds = service.getRandomAds();
        }
        if (allAds.isEmpty()) {
          // Serve random ads.
          allAds = service.getRandomAds();
        }
        AdResponse reply = AdResponse.newBuilder().addAllAds(allAds).build();
        responseObserver.onNext(reply);
        responseObserver.onCompleted();
      } catch (StatusRuntimeException e) {
        logger.log(Level.WARN, "GetAds Failed with status {}", e.getStatus());
        responseObserver.onError(e);
      }
    }
  }

  private static final ImmutableListMultimap<String, Ad> adsMap = createAdsMap();

  private Collection<Ad> getAdsByCategory(String category) {
    return adsMap.get(category);
  }

  private static final Random random = new Random();

  private List<Ad> getRandomAds() {
    List<Ad> ads = new ArrayList<>(MAX_ADS_TO_SERVE);
    Collection<Ad> allAds = adsMap.values();
    for (int i = 0; i < MAX_ADS_TO_SERVE; i++) {
      ads.add(Iterables.get(allAds, random.nextInt(allAds.size())));
    }
    ad_analytics();
    

    return ads;
  }

  private void ad_analytics(){
    String[] advertisers = {"Fruit Tree", "Vegetable Garden", "Good Food", "Fun Toys"};

    String advertiser;
    int time = (int) (new Date().getTime()/1000L) % 300; // 5 minute repeating schedule
    int rand = random.nextInt(10);
    int adid = random.nextInt(100);
    

    if (time < 15) {
        logger.info("Advertiser '"+ advertisers [ 0 ] + "' on");
        logger.info("Advertiser '"+ advertisers [ 1 ] + "' on");
        logger.info("Advertiser '"+ advertisers [ 2 ] + "' on");
        logger.info("Advertiser '"+ advertisers [ 3 ] + "' on");
    } else if ((time < 165) && (time > 145)) {
        logger.info("Advertiser '"+ advertisers [ 1 ] + "' off");
    }

    //not relying on time to make sure that regarless of execution patterns
    // we have a defined distribution of advertisers.
    if (rand < 2){ //20% of the time
        advertiser = advertisers[3];
    } else if (rand < 5) { //30% of the time
        advertiser = advertisers[2];
    } else if (rand == 5) { //10% of the time
        advertiser = advertisers[1];
    } else { //40% of the time
        advertiser = advertisers[0];
    }

    logger.debug("Ad selected. Advertiser '" + advertiser + "'");
    //Let's create interesting error logs here
    if (adid < 20) { //we are generating an error log for 20% of the requests
        logger.error("Unable to display ad id " + adid);
        //We will generate 3 more different error patterns
        if (adid < 10){
            logger.error("Ad id " + adid + " has malformed JSON in line " + adid * 2 );
        } else if (adid < 14){
            logger.error("Unable to connect to the ad network for advertiser '" + advertiser + "'");
        } else if (adid < 17){
            logger.error("Unknown ad id " + adid);
        } else {
            logger.error("Invalid combination. Advertiser: '" + advertiser + "' Ad id: " + adid);
        }
    } else {
        //ad impression
        logger.info("Ad seen. Advertiser '" + advertiser + "'");
    }
  }

  private static AdService getInstance() {
    return service;
  }

  /** Await termination on the main thread since the grpc library uses daemon threads. */
  private void blockUntilShutdown() throws InterruptedException {
    if (server != null) {
      server.awaitTermination();
    }
  }

  private static ImmutableListMultimap<String, Ad> createAdsMap() {
    Ad tshirt2 =
        Ad.newBuilder()
            .setRedirectUrl("/product/2ZYFJ3GM2N")
            .setText("T-shirt for sale. 50% off.")
            .build();
    Ad tshirt =
        Ad.newBuilder()
            .setRedirectUrl("/product/66VCHSJNUP")
            .setText("T-shirt for sale. 20% off.")
            .build();
    Ad headphones =
        Ad.newBuilder()
            .setRedirectUrl("/product/0PUK6V6EV0")
            .setText("Headphones for sale. 30% off.")
            .build();
    Ad sweatshirt =
        Ad.newBuilder()
            .setRedirectUrl("/product/9SIQT8TOJO")
            .setText("Sweatshirt for sale. 10% off.")
            .build();
    Ad dogsteel =
        Ad.newBuilder()
            .setRedirectUrl("/product/1YMWWN1N4O")
            .setText("Steel bottle for sale. Buy one, get second kit for free")
            .build();
    Ad mug =
        Ad.newBuilder()
            .setRedirectUrl("/product/LS4PSXUNUM")
            .setText("Mug for sale. Buy two, get third one for free")
            .build();
    Ad notebook =
        Ad.newBuilder()
            .setRedirectUrl("/product/L9ECAV7KIM")
            .setText("Notebook for sale. Buy one, get second one for free")
            .build();
    return ImmutableListMultimap.<String, Ad>builder()
        .putAll("clothing", tshirt, sweatshirt, tshirt2)
        .putAll("accessories", dogsteel, mug, headphones, notebook)
        .putAll("kitchen", dogsteel, mug)
        .putAll("office", notebook, headphones)
        .build();
  }

  private static void initStats() {
    if (System.getenv("DISABLE_STATS") != null) {
      logger.info("Stats disabled.");
      return;
    }
    logger.info("Stats enabled, but temporarily unavailable");

    long sleepTime = 10; /* seconds */
    int maxAttempts = 5;

    // TODO(arbrown) Implement OpenTelemetry stats

  }

  private static void initTracing() {
    if (System.getenv("DISABLE_TRACING") != null) {
      logger.info("Tracing disabled.");
      return;
    }
    logger.info("Tracing enabled but temporarily unavailable");
    logger.info("See https://github.com/GoogleCloudPlatform/microservices-demo/issues/422 for more info.");

    // TODO(arbrown) Implement OpenTelemetry tracing
    
    logger.info("Tracing enabled - Stackdriver exporter initialized.");
  }

  /** Main launches the server from the command line. */
  public static void main(String[] args) throws IOException, InterruptedException {

    new Thread(
            () -> {
              initStats();
              initTracing();
            })
        .start();

    // Start the RPC server. You shouldn't see any output from gRPC before this.
    logger.info("AdService starting.");
    final AdService service = AdService.getInstance();
    service.start();
    service.blockUntilShutdown();
  }
}
