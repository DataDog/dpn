package com.hipstershop.paymentservicejava;

import java.nio.charset.Charset;
import java.util.Random;
import java.util.logging.Level;
import java.util.logging.Logger;


import org.springframework.beans.factory.annotation.Autowired;

import com.google.protobuf.Any;
import com.google.rpc.ErrorInfo;

import hipstershop.PaymentServiceGrpc;
import hipstershop.Payment.ChargeRequest;
import hipstershop.Payment.ChargeResponse;
import io.grpc.protobuf.StatusProto;
import net.devh.boot.grpc.server.service.GrpcService;

@GrpcService
public class PaymentServiceImpl extends PaymentServiceGrpc.PaymentServiceImplBase {
    
    private Logger log = Logger.getLogger("PaymentServiceImpl");

    @Autowired
    PaymentController controller;

    @Override
    public void charge(ChargeRequest request,
        io.grpc.stub.StreamObserver<ChargeResponse> responseObserver) {
            log.info("Charge request received. Storing credit card details for latent charging and chargebacks.");
                    
            String ccNumber = request.getCreditCard().getCreditCardNumber();
        
            if("0408-1516-2300-4200".equals(ccNumber)) {
                log.finest("Test credit card number received. Will not charge the card.");
            }
            
            String transactionId = "none";
            try {
                transactionId = controller.clearPayment(request);
            } catch(Exception e) {
                this.log.log(Level.SEVERE, e.getClass().getName() + " occurred. Cannot process payment transaction.");
                com.google.rpc.Status status = com.google.rpc.Status.newBuilder()
                .setCode(com.google.rpc.Code.UNAVAILABLE_VALUE)
                .setMessage(e.getClass().getName())
                .addDetails(Any.pack(ErrorInfo.newBuilder()
                    .setReason(e.getMessage())
                    .setDomain("hipstershop.paymentserviceimpl")
                    .build()))
                .build();
                responseObserver.onError(StatusProto.toStatusRuntimeException(status));

            }
            // build the response
            ChargeResponse reply = ChargeResponse.newBuilder().
                setTransactionId(transactionId).
                build();

            responseObserver.onNext(reply);
            responseObserver.onCompleted();            
    }    

}
